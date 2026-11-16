// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReplacementTestBase} from "./ReplacementTestBase.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {IMDBurnQueue} from "../../src/bridge/IMDBurnQueue.sol";
import {GardenEconomy} from "../../src/GardenEconomy.sol";
import {WishText} from "../../src/WishText.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WalletGas} from "../helpers/WalletGas.sol";

contract ReplacementGardenTest is ReplacementTestBase, WalletGas {
    function testFuzz_paymentStylesPositionsAndConservation(uint8 q, uint8 s) public {
        uint256 n = bound(q, 1, 50);
        uint8 style = uint8(bound(s, 0, 6));
        uint256 first = _buy(n, style, unicode"希望 🌱");
        assertEq(first, PREFIX + 1);
        for (uint256 i; i < n; ++i) {
            WishGarden.Candle memory c = garden.getCandle(first + i);
            assertEq(c.position, PREFIX + i);
            assertEq(c.purchaser, alice);
            assertEq(c.style, style);
            assertFalse(c.freeClaim);
            (address author, string memory text) = garden.wishOf(first + i);
            assertEq(author, alice);
            assertEq(text, unicode"希望 🌱");
        }
        _assertAccounting(n);
        assertEq(token.balanceOf(address(treasury)), n * 1e18);
        assertEq(token.allowance(alice, address(garden)), 0);
    }

    function test_recordsNeverExpireAndCanonicalNamespacesDiffer() public {
        uint256 id = _buy(1, 6, "permanent");
        bytes32 beforeRecord = keccak256(abi.encode(garden.getCandle(id)));
        bytes32 key = garden.candleKey(id);
        vm.warp(block.timestamp + 100 * 365 days);
        _buy(50, 0, "");
        assertEq(keccak256(abi.encode(garden.getCandle(id))), beforeRecord);
        assertEq(garden.candleKey(id), key);
        assertTrue(registry.candleKey(id) != key);
        assertTrue(registry.candleKey(1) != key);
    }

    function test_paidOnlyNoSecondClaimEntrypointOrLedger() public {
        vm.startPrank(alice);
        (bool ok,) = address(garden).call(abi.encodeWithSignature("claimFreeCandle(uint256,uint8)", 7, 2));
        assertFalse(ok);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        (ok,) = address(garden).call(abi.encodeWithSignature("claimFreeCandles(uint256[],uint8)", ids, 2));
        assertFalse(ok);
        (ok,) = address(garden).call(abi.encodeWithSignature("confirmOfficialCollection(bytes32)", EVIDENCE));
        assertFalse(ok);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
    }

    function test_boundsEmptyPurchaseAndPages() public {
        vm.startPrank(alice);
        token.approve(address(garden), 100e18);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 0));
        garden.buyCandles(0, 0);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 51));
        garden.buyCandles(51, 0);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.InvalidStyle.selector, 7));
        garden.buyCandles(1, 7);
        vm.stopPrank();
        (WishGarden.Candle[] memory empty, uint256 next) = garden.getCandles(PREFIX + 1, 100);
        assertEq(empty.length, 0);
        assertEq(next, PREFIX + 1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(1, 100);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(PREFIX + 1, 101);
        _buy(3, 0, "");
        (uint256[] memory page, uint256 offset) = garden.candleIdsOf(alice, 1, 100);
        assertEq(page.length, 2);
        assertEq(page[0], PREFIX + 2);
        assertEq(offset, 3);
        (address author, string memory text) = garden.wishOf(PREFIX + 1);
        assertEq(author, alice);
        assertEq(text, "");
        vm.expectRevert();
        garden.getCandle(PREFIX);
    }

    function test_namespaceBoundaryReservesExclusivePageCursor() public {
        // Synthetic unreachable-sized history reproduces arithmetic boundary without billions of writes.
        vm.store(address(garden), bytes32(uint256(3)), bytes32(PREFIX - 2));
        assertEq(garden.totalCandles(), PREFIX - 2);
        (WishGarden.Candle[] memory page, uint256 next) = garden.getCandles(type(uint256).max, 1);
        assertEq(page.length, 0);
        assertEq(next, type(uint256).max);
        vm.prank(alice);
        token.approve(address(garden), 1e18);
        vm.prank(alice);
        vm.expectRevert(WishGarden.NamespaceExhausted.selector);
        garden.buyCandles(1, 0);
    }

    function test_acknowledgementAndNoWishMutation() public {
        vm.startPrank(alice);
        token.approve(address(garden), 1e18);
        vm.expectRevert(WishText.PublicAcknowledgementRequired.selector);
        garden.buyCandlesWithWish(1, 0, "public forever", false);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
        uint256 id = _buy(1, 0, "public forever");
        vm.prank(OWNER);
        (bool ok,) =
            address(garden).call(abi.encodeWithSignature("setWish(uint256,string)", id, "overwritten"));
        assertFalse(ok);
        (, string memory text) = garden.wishOf(id);
        assertEq(text, "public forever");
    }

    function test_paymentFailuresRollbackTextAllowanceRecordsAndBuckets() public {
        for (uint8 mode = 1; mode <= 4; ++mode) {
            token.configureModes(mode, 0, address(0));
            vm.startPrank(alice);
            token.approve(address(garden), 2e18);
            vm.expectRevert();
            garden.buyCandlesWithWish(2, 0, "retry", true);
            vm.stopPrank();
            assertEq(token.allowance(alice, address(garden)), 2e18);
            _assertAccounting(0);
        }
        token.configureModes(0, 2, address(treasury));
        vm.prank(alice);
        vm.expectRevert();
        garden.buyCandlesWithWish(2, 0, "retry", true);
        assertEq(garden.wishBatch(PREFIX + 1), 0);
        token.configureModes(0, 0, address(0));
        _buy(2, 0, "retry");
        _assertAccounting(2);
    }

    function test_noReturnTokenStillRequiresExactMovement() public {
        token.configureModes(5, 5, address(0));
        _buy(3, 0, "no return");
        _assertAccounting(3);
    }

    function test_reentrancyCannotDuplicatePaidWish() public {
        token.configureCallback(address(garden), abi.encodeCall(garden.buyCandles, (1, 0)), true, true);
        _buy(2, 0, "guarded");
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        _assertAccounting(2);
    }

    function test_donationsNotRevenueAndCannotSpendVictimApproval() public {
        vm.prank(alice);
        token.transfer(address(treasury), 10e18);
        assertEq(treasury.unallocatedBalance(), 10e18);
        vm.prank(OWNER);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        treasury.withdrawFounder(OWNER, 1);
        vm.prank(alice);
        token.approve(address(garden), 10e18);
        vm.prank(bob);
        vm.expectRevert();
        garden.buyCandles(1, 0);
        _assertAccounting(0);
        _buy(1, 0, "");
        assertEq(treasury.unallocatedBalance(), 10e18);
    }

    function test_maximumBatchWithMaximumTextAtWalletGas() public {
        bytes memory data = new bytes(1120);
        for (uint256 i; i < 280; ++i) {
            data[i * 4] = 0xf0;
            data[i * 4 + 1] = 0x9f;
            data[i * 4 + 2] = 0x8c;
            data[i * 4 + 3] = 0xb1;
        }
        vm.prank(alice);
        token.approve(address(garden), 50e18);
        assertSameAtWalletGas(
            alice, address(garden), abi.encodeCall(garden.buyCandlesWithWish, (50, 6, string(data), true))
        );
        _buy(50, 6, string(data));
        _assertAccounting(50);
    }

    function test_wrongChainAndNativePaymentFailClosed() public {
        vm.chainId(8453);
        vm.expectRevert();
        garden.buyCandles(1, 0);
        vm.chainId(1);
        (bool ok,) = address(garden).call{value: 1}(abi.encodeCall(garden.buyCandles, (1, 0)));
        assertFalse(ok);
    }
}

contract ReplacementTreasuryTest is ReplacementTestBase {
    function test_allThreeOwnerWithdrawalsSeparateEventsAndBurnProtected() public {
        _buy(10, 1, "");
        vm.startPrank(OWNER);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit WishGardenTreasury.BucketWithdrawn(WishGardenTreasury.Bucket.Ecosystem, OWNER, bob, 5e18);
        treasury.withdrawEcosystem(bob, 5e18);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit WishGardenTreasury.BucketWithdrawn(WishGardenTreasury.Bucket.Operations, OWNER, bob, 1e18);
        treasury.withdrawOperations(bob, 1e18);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit WishGardenTreasury.BucketWithdrawn(WishGardenTreasury.Bucket.Founder, OWNER, bob, 1e18);
        treasury.withdrawFounder(bob, 1e18);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        treasury.withdrawEcosystem(OWNER, 1);
        (bool ok,) =
            address(treasury).call(abi.encodeWithSignature("withdrawBurn(address,uint256)", OWNER, 3e18));
        assertFalse(ok);
        vm.stopPrank();
        assertEq(token.balanceOf(address(treasury)), 3e18);
        _assertAccounting(10);
    }

    function test_transferredOwnerCanWithdrawOperationsAndFounderOldOwnerCannot() public {
        _buy(1, 0, "");
        vm.prank(OWNER);
        treasury.transferOwnership(bob);
        vm.prank(bob);
        treasury.acceptOwnership();
        vm.prank(OWNER);
        vm.expectRevert();
        treasury.withdrawOperations(OWNER, 0.1e18);
        vm.startPrank(bob);
        treasury.withdrawOperations(bob, 0.1e18);
        treasury.withdrawFounder(bob, 0.1e18);
        vm.stopPrank();
        _assertAccounting(1);
    }

    function testFuzz_withdrawalFailureAndPartialConservation(uint8 q, uint96 a) public {
        uint256 n = bound(q, 1, 50);
        _buy(n, 0, "");
        uint256 amount = bound(a, 1, n * 0.5e18);
        token.configureModes(0, 2, bob);
        vm.prank(OWNER);
        vm.expectRevert(GardenEconomy.InexactTransfer.selector);
        treasury.withdrawEcosystem(bob, amount);
        assertEq(treasury.totalEcosystemWithdrawn(), 0);
        token.configureModes(0, 0, address(0));
        vm.prank(OWNER);
        treasury.withdrawEcosystem(bob, amount);
        _assertAccounting(n);
    }

    function test_unprivilegedAllBucketsRecordAndConfigurationRejected() public {
        vm.startPrank(alice);
        vm.expectRevert();
        treasury.withdrawEcosystem(alice, 1);
        vm.expectRevert();
        treasury.withdrawOperations(alice, 1);
        vm.expectRevert();
        treasury.withdrawFounder(alice, 1);
        vm.expectRevert(WishGardenTreasury.OnlyGarden.selector);
        treasury.recordPayment(alice, 1, 1);
        vm.expectRevert();
        treasury.activatePurchases();
        vm.expectRevert();
        treasury.freezeBridge(
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, GAS, SALT, EVIDENCE
        );
        vm.stopPrank();
    }

    function test_ownerReentryAcrossBucketsRejected() public {
        _buy(1, 0, "");
        vm.prank(OWNER);
        treasury.transferOwnership(IMD);
        vm.prank(IMD);
        treasury.acceptOwnership();
        token.configureCallback(
            address(treasury), abi.encodeCall(treasury.withdrawFounder, (bob, 0.1e18)), false, true
        );
        vm.prank(IMD);
        treasury.withdrawOperations(bob, 0.1e18);
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(treasury.founderBalance(), 0.1e18);
        _assertAccounting(1);
    }

    function test_configurationFrozenActivationOnceAndRenounceRejected() public {
        vm.startPrank(OWNER);
        vm.expectRevert(IMDBurnQueue.ConfigurationFrozen.selector);
        treasury.freezeBridge(
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, GAS, SALT, EVIDENCE
        );
        vm.expectRevert(IMDBurnQueue.AlreadyActive.selector);
        treasury.activatePurchases();
        vm.expectRevert(IMDBurnQueue.OwnershipRequired.selector);
        treasury.renounceOwnership();
        vm.expectRevert(WishGarden.OwnershipRequired.selector);
        garden.renounceOwnership();
        vm.stopPrank();
    }
}
