// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GardenTestBase} from "./helpers/GardenTestBase.sol";
import {LegacyWishGarden as WishGarden} from "./legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "./legacy-src/LegacyWishGardenTreasury.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GardenEconomy} from "../src/GardenEconomy.sol";

contract WishGardenTreasuryTest is GardenTestBase {
    function test_bucketWithdrawalsAndClaimsAreSeparateWithDestinationEvents() public {
        _buy(alice, 10, 0);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit WishGardenTreasury.BucketWithdrawn(WishGardenTreasury.Bucket.Ecosystem, OWNER, bob, 2e18);
        vm.prank(OWNER);
        treasury.withdrawEcosystem(bob, 2e18);
        assertEq(treasury.ecosystemBalance(), 3e18);
        assertEq(treasury.operationsBalance(), 1e18);
        assertEq(treasury.founderBalance(), 1e18);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit WishGardenTreasury.BucketWithdrawn(
            WishGardenTreasury.Bucket.Operations, operations, operations, 1e18
        );
        vm.prank(operations);
        treasury.claimOperations(1e18);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit WishGardenTreasury.BucketWithdrawn(WishGardenTreasury.Bucket.Founder, founder, founder, 0.5e18);
        vm.prank(founder);
        treasury.claimFounder(0.5e18);
        assertEq(token.balanceOf(operations), 1e18);
        assertEq(token.balanceOf(founder), 0.5e18);
        assertEq(treasury.founderBalance(), 0.5e18);
        _assertAccounting(10);
    }

    function test_ownerCannotTakeOperationsFounderOrBurnAllocations() public {
        _buy(alice, 10, 0);
        vm.startPrank(OWNER);
        vm.expectRevert(WishGardenTreasury.UnauthorizedBeneficiary.selector);
        treasury.claimOperations(1e18);
        vm.expectRevert(WishGardenTreasury.UnauthorizedBeneficiary.selector);
        treasury.claimFounder(1e18);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        treasury.withdrawEcosystem(OWNER, 5e18 + 1);
        treasury.withdrawEcosystem(OWNER, 5e18);
        vm.stopPrank();
        assertEq(treasury.accountedBalance(), 2e18);
        assertEq(token.balanceOf(address(sink)), 3e18);
        // The sink has no arbitrary execution, transfer, approval, or withdrawal entrypoint.
        vm.prank(OWNER);
        (bool ok,) = address(sink).call(abi.encodeWithSignature("withdraw(address,uint256)", OWNER, 3e18));
        assertFalse(ok);
        _assertAccounting(10);
    }

    function test_unauthorizedAndOverdrawnWithdrawalsRevert() public {
        _buy(alice, 1, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        treasury.withdrawEcosystem(alice, 1);
        vm.prank(founder);
        vm.expectRevert(WishGardenTreasury.UnauthorizedBeneficiary.selector);
        treasury.claimOperations(1);
        vm.prank(operations);
        vm.expectRevert(WishGardenTreasury.UnauthorizedBeneficiary.selector);
        treasury.claimFounder(1);
        vm.prank(operations);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        treasury.claimOperations(0.1e18 + 1);
        vm.prank(founder);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        treasury.claimFounder(0.1e18 + 1);
        _assertAccounting(1);
    }

    function test_invalidWithdrawalAmountAndDestinationRollBackAccounting() public {
        _buy(alice, 1, 0);
        address[5] memory invalid = [address(0), address(sink), address(treasury), address(garden), IMD];
        vm.startPrank(OWNER);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        treasury.withdrawEcosystem(bob, 0);
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
            treasury.withdrawEcosystem(invalid[i], 1);
        }
        vm.stopPrank();
        vm.prank(operations);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        treasury.claimOperations(0);
        vm.prank(founder);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        treasury.claimFounder(0);
        _assertAccounting(1);
    }

    function test_onlyBoundGardenCanRecordAndFundingCannotBeReused() public {
        vm.prank(alice);
        vm.expectRevert(WishGardenTreasury.OnlyGarden.selector);
        treasury.recordPayment(alice, 1, 1);
        _buy(alice, 1, 0);
        vm.prank(address(garden));
        vm.expectRevert(WishGardenTreasury.InsufficientFunding.selector);
        treasury.recordPayment(alice, 2, 1);
        _assertAccounting(1);
    }

    function test_bindingIsOwnerOnlyOnceAndValidatesReciprocalReferences() public {
        WishGardenTreasury pending = new WishGardenTreasury(OWNER, address(sink), operations, founder);
        WishGarden validGarden = new WishGarden(OWNER, address(pending));
        WishGarden wrongOwnerGarden = new WishGarden(alice, address(pending));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pending.bindGarden(address(validGarden));
        vm.startPrank(OWNER);
        vm.expectRevert(WishGardenTreasury.InvalidGarden.selector);
        pending.bindGarden(alice);
        vm.expectRevert(WishGardenTreasury.InvalidGarden.selector);
        pending.bindGarden(address(garden));
        vm.expectRevert(WishGardenTreasury.InvalidGarden.selector);
        pending.bindGarden(address(wrongOwnerGarden));
        pending.bindGarden(address(validGarden));
        vm.expectRevert(WishGardenTreasury.GardenAlreadyBound.selector);
        pending.bindGarden(address(validGarden));
        vm.stopPrank();
        assertEq(pending.garden(), address(validGarden));
    }

    function test_arbitraryBurnSinkFailsBindingAndRuntimeChangeRevertsPurchase() public {
        WishGardenTreasury bad = new WishGardenTreasury(OWNER, bob, operations, founder);
        WishGarden badGarden = new WishGarden(OWNER, address(bad));
        vm.prank(OWNER);
        vm.expectRevert(WishGardenTreasury.InvalidBurnSink.selector);
        bad.bindGarden(address(badGarden));
        vm.etch(address(sink), address(garden).code);
        vm.startPrank(alice);
        token.approve(address(garden), 1e18);
        vm.expectRevert(WishGardenTreasury.InvalidBurnSink.selector);
        garden.buyCandles(1, 0);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
        assertEq(treasury.totalPayments(), 0);
        assertEq(token.balanceOf(address(treasury)), 0);
    }

    function test_twoStepOwnerTransferDoesNotChangeFixedBeneficiaries() public {
        _buy(alice, 1, 0);
        vm.prank(OWNER);
        treasury.transferOwnership(bob);
        assertEq(treasury.owner(), OWNER);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        treasury.withdrawEcosystem(bob, 1);
        vm.prank(bob);
        treasury.acceptOwnership();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        treasury.withdrawEcosystem(OWNER, 1);
        vm.prank(bob);
        treasury.withdrawEcosystem(bob, 0.5e18);
        vm.prank(bob);
        vm.expectRevert(WishGardenTreasury.UnauthorizedBeneficiary.selector);
        treasury.claimFounder(0.1e18);
        assertEq(treasury.operationsRecipient(), operations);
        assertEq(treasury.founderRecipient(), founder);
        _assertAccounting(1);
    }

    function test_ownershipCannotBeRenounced() public {
        vm.startPrank(OWNER);
        vm.expectRevert(WishGardenTreasury.OwnershipRequired.selector);
        treasury.renounceOwnership();
        vm.expectRevert(WishGarden.OwnershipRequired.selector);
        garden.renounceOwnership();
        vm.stopPrank();
    }

    function test_unallocatedDonationsCannotBeWithdrawnAsRevenue() public {
        vm.prank(alice);
        token.transfer(address(treasury), 10e18);
        assertEq(treasury.unallocatedBalance(), 10e18);
        vm.prank(OWNER);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        treasury.withdrawEcosystem(OWNER, 1);
        assertEq(treasury.totalPayments(), 0);
    }

    function testFuzz_bucketConservationAfterPartialWithdrawals(uint8 quantitySeed, uint96 amountSeed)
        public
    {
        uint256 quantity = bound(uint256(quantitySeed), 1, 50);
        _buy(alice, quantity, 0);
        uint256 amount = bound(uint256(amountSeed), 1, quantity * 0.5e18);
        vm.prank(OWNER);
        treasury.withdrawEcosystem(bob, amount);
        vm.prank(operations);
        treasury.claimOperations(quantity * 0.1e18);
        vm.prank(founder);
        treasury.claimFounder(quantity * 0.1e18);
        _assertAccounting(quantity);
    }
}
