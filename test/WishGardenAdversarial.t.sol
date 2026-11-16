// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GardenTestBase} from "./helpers/GardenTestBase.sol";
import {AdversarialIMD} from "./helpers/AdversarialIMD.sol";
import {GardenEconomy} from "../src/GardenEconomy.sol";
import {LegacyWishGarden as WishGarden} from "./legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "./legacy-src/LegacyWishGardenTreasury.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract WishGardenAdversarialTest is GardenTestBase {
    AdversarialIMD internal faulty;

    function setUp() public override {
        super.setUp();
        AdversarialIMD implementation = new AdversarialIMD();
        vm.etch(IMD, address(implementation).code);
        faulty = AdversarialIMD(IMD);
        faulty.configureModes(0, 0, address(0));
        faulty.configureCallback(address(0), "", false, false);
        faulty.mint(alice, 1000e18);
    }

    function test_falseReturnOnPullRollsBackTokenTransfersAndAllRecords() public {
        faulty.configureModes(1, 0, address(0));
        _expectFailedPurchase(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
    }

    function test_feeOnPullRejectedEvenWithUnsolicitedDonation() public {
        faulty.mint(address(garden), 50e18);
        faulty.configureModes(2, 0, address(0));
        _expectFailedPurchase(abi.encodeWithSelector(GardenEconomy.InexactTransfer.selector));
        assertEq(token.balanceOf(address(garden)), 50e18);
    }

    function test_extraBuyerDebitIsRejected() public {
        faulty.configureModes(4, 0, address(0));
        _expectFailedPurchase(abi.encodeWithSelector(GardenEconomy.InexactTransfer.selector));
    }

    function test_successWithoutPullingFundsCannotCreateCandles() public {
        faulty.configureModes(3, 0, address(0));
        _expectFailedPurchase(abi.encodeWithSelector(GardenEconomy.InexactTransfer.selector));
    }

    function test_failedTransferToTreasuryRollsBackPurchase() public {
        faulty.configureModes(0, 1, address(treasury));
        _expectFailedPurchase(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
    }

    function test_taxedTransferToTreasuryIsRejected() public {
        faulty.configureModes(0, 2, address(treasury));
        _expectFailedPurchase(abi.encodeWithSelector(GardenEconomy.InexactTransfer.selector));
    }

    function test_failedFinalSinkTransferRollsBackEverythingIncludingAllowance() public {
        faulty.configureModes(0, 1, address(sink));
        _expectFailedPurchase(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
    }

    function test_inexactSinkTransferCannotBeReportedAsLockedOrSupplyBurned() public {
        faulty.configureModes(0, 2, address(sink));
        _expectFailedPurchase(abi.encodeWithSelector(GardenEconomy.InexactTransfer.selector));
    }

    function test_noReturnTokenOperationsAreCheckedByBalanceDeltas() public {
        faulty.configureModes(5, 5, address(0));
        _buy(alice, 10, 0);
        _assertAccounting(10);
    }

    function test_failedWithdrawalPreservesBucketAndClaimableAmount() public {
        _buy(alice, 10, 0);
        faulty.configureModes(0, 1, bob);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        treasury.withdrawEcosystem(bob, 5e18);
        faulty.configureModes(0, 2, operations);
        vm.prank(operations);
        vm.expectRevert(GardenEconomy.InexactTransfer.selector);
        treasury.claimOperations(1e18);
        assertEq(treasury.totalEcosystemWithdrawn(), 0);
        assertEq(treasury.totalOperationsClaimed(), 0);
        _assertAccounting(10);
    }

    function test_reentrantPurchaseRejectedWhileOriginalCompletesOnce() public {
        faulty.configureCallback(address(garden), abi.encodeCall(garden.buyCandles, (1, 0)), true, false);
        _buy(alice, 1, 0);
        _assertCallbackGuard();
        assertEq(garden.totalCandles(), 1);
        _assertAccounting(1);
    }

    function test_crossFunctionReentrantFreeClaimRejected() public {
        _confirmCollection();
        _mintNFT(IMD, 0);
        faulty.configureCallback(address(garden), abi.encodeCall(garden.claimFreeCandle, (0, 0)), true, false);
        _buy(alice, 1, 0);
        _assertCallbackGuard();
        assertEq(garden.freeCandles(), 0);
        assertEq(garden.nftClaimedCandle(0), 0);
        _assertAccounting(1);
    }

    function test_authorizedOwnerCannotReenterTreasuryWithdrawalThroughTokenCallback() public {
        _buy(alice, 10, 0);
        vm.prank(OWNER);
        treasury.transferOwnership(IMD);
        vm.prank(IMD);
        treasury.acceptOwnership();
        faulty.configureCallback(
            address(treasury), abi.encodeCall(treasury.withdrawEcosystem, (bob, 1e18)), false, true
        );
        vm.prank(IMD);
        treasury.withdrawEcosystem(bob, 1e18);
        _assertCallbackGuard();
        assertEq(treasury.totalEcosystemWithdrawn(), 1e18);
        _assertAccounting(10);
    }

    function _expectFailedPurchase(bytes memory reason) private {
        uint256 supply = token.totalSupply();
        uint256 buyerBalance = token.balanceOf(alice);
        uint256 gardenBalance = token.balanceOf(address(garden));
        vm.startPrank(alice);
        token.approve(address(garden), 10e18);
        vm.expectRevert(reason);
        garden.buyCandles(10, 0);
        vm.stopPrank();
        assertEq(token.allowance(alice, address(garden)), 10e18);
        assertEq(token.balanceOf(alice), buyerBalance);
        assertEq(token.balanceOf(address(garden)), gardenBalance);
        assertEq(token.balanceOf(address(treasury)), 0);
        assertEq(token.balanceOf(address(sink)), 0);
        assertEq(token.totalSupply(), supply);
        assertEq(garden.totalCandles(), 0);
        assertEq(garden.candleCountOf(alice), 0);
        assertEq(garden.paidCandles(), 0);
        assertEq(treasury.totalPayments(), 0);
        assertEq(treasury.totalIMDLocked(), 0);
        assertEq(treasury.accountedBalance(), 0);
        assertEq(treasury.totalSupplyBurned(), 0);
    }

    function _assertCallbackGuard() private view {
        assertTrue(faulty.callbackAttempted());
        assertFalse(faulty.callbackSucceeded());
        assertEq(
            faulty.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }
}
