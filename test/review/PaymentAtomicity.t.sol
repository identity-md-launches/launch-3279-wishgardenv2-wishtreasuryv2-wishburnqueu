// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReplacementTestBase} from "../replacement/ReplacementTestBase.sol";
import {WishGarden} from "src/WishGarden.sol";
import {WishGardenTreasury} from "src/WishGardenTreasury.sol";

contract PaymentAtomicityReviewTest is ReplacementTestBase {
    function setUp() public override {
        super.setUp();
        _buy(3, 4, "earlier immutable wish");
        // Donations must neither hide a deficient transfer nor become withdrawable revenue.
        token.mint(address(garden), 17e18);
        token.mint(address(treasury), 23e18);
    }

    function testFuzz_bothTransferLegsRollbackCompletePurchaseAndRetry(
        uint8 quantitySeed,
        uint8 styleSeed,
        uint8 modeSeed,
        bool push
    ) public {
        uint256 quantity = bound(quantitySeed, 1, 50);
        uint8 style = styleSeed % 7;
        uint8 mode = modeSeed % 4 + 1; // false return, recipient tax, no movement, sender surcharge
        vm.prank(alice);
        token.approve(address(garden), quantity * 1e18);
        token.configureModes(push ? 0 : mode, push ? mode : 0, address(treasury));
        bytes32 beforeState = _financialState();
        bytes32 existing = keccak256(abi.encode(garden.getCandle(PREFIX + 1)));
        vm.prank(alice);
        vm.expectRevert();
        garden.buyCandlesWithWish(quantity, style, unicode"a new wish 🌱", true);
        assertEq(_financialState(), beforeState, "failed transfer must restore every recorded balance");
        assertEq(keccak256(abi.encode(garden.getCandle(PREFIX + 1))), existing);
        assertEq(garden.candleCountOf(alice), 3);
        for (uint256 i; i < quantity; ++i) {
            uint256 id = PREFIX + 4 + i;
            assertEq(garden.wishBatch(id), 0);
            vm.expectRevert(abi.encodeWithSelector(WishGarden.CandleNotFound.selector, id));
            garden.getCandle(id);
        }
        token.configureModes(0, 0, address(0));
        vm.prank(alice);
        uint256 first = garden.buyCandlesWithWish(quantity, style, unicode"a new wish 🌱", true);
        assertEq(first, PREFIX + 4);
        assertEq(token.allowance(alice, address(garden)), 0);
        assertEq(token.balanceOf(address(garden)), 17e18);
        assertEq(treasury.unallocatedBalance(), 23e18);
        _assertAccounting(3 + quantity);
        for (uint256 i; i < quantity; ++i) {
            (address author, string memory wish) = garden.wishOf(first + i);
            assertEq(author, alice);
            assertEq(wish, unicode"a new wish 🌱");
            assertEq(garden.getCandle(first + i).position, first + i - 1);
        }
    }

    function testFuzz_everyWithdrawalBucketRestoresEntitlementOnTokenFault(
        uint8 bucketSeed,
        uint8 modeSeed,
        uint96 amountSeed
    ) public {
        uint8 bucket = bucketSeed % 3;
        uint256 entitlement = bucket == 0 ? 1.5e18 : 0.3e18;
        uint256 amount = bound(amountSeed, 1, entitlement);
        token.configureModes(0, modeSeed % 4 + 1, bob);
        bytes32 beforeState = _financialState();
        vm.prank(OWNER);
        vm.expectRevert();
        _withdraw(bucket, bob, amount);
        assertEq(_financialState(), beforeState);
        token.configureModes(0, 0, address(0));
        uint256 recipient = token.balanceOf(bob);
        vm.prank(OWNER);
        _withdraw(bucket, bob, amount);
        assertEq(token.balanceOf(bob), recipient + amount);
        assertEq(treasury.pendingBurn(), 0.9e18);
        assertEq(treasury.unallocatedBalance(), 23e18);
        _assertAccounting(3);
    }

    function testFuzz_allBucketsRejectForbiddenDestinationsAndOverdraw(
        uint8 bucketSeed,
        uint8 destinationSeed
    ) public {
        uint8 bucket = bucketSeed % 3;
        address[4] memory forbidden = [address(0), address(treasury), address(garden), IMD];
        uint256 entitlement = bucket == 0 ? 1.5e18 : 0.3e18;
        bytes32 beforeState = _financialState();
        vm.prank(OWNER);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        _withdraw(bucket, forbidden[destinationSeed % 4], 1);
        vm.prank(OWNER);
        vm.expectRevert(WishGardenTreasury.InvalidWithdrawal.selector);
        _withdraw(bucket, bob, 0);
        vm.prank(OWNER);
        vm.expectRevert(WishGardenTreasury.InsufficientBucketBalance.selector);
        _withdraw(bucket, bob, entitlement + 1);
        assertEq(_financialState(), beforeState);
    }

    function test_noReturnTokensPayAllBucketsExactlyAndLeaveDonationsAndBurnIntact() public {
        token.configureModes(5, 5, address(0));
        vm.startPrank(bob);
        token.approve(address(garden), 50e18);
        uint256 id = garden.buyCandlesWithWish(50, 6, "public", true);
        vm.stopPrank();
        assertEq(id, PREFIX + 4);
        uint256 beforeBalance = token.balanceOf(bob);
        vm.startPrank(OWNER);
        treasury.withdrawEcosystem(bob, 26.5e18);
        treasury.withdrawOperations(bob, 5.3e18);
        treasury.withdrawFounder(bob, 5.3e18);
        vm.stopPrank();
        assertEq(token.balanceOf(bob) - beforeBalance, 37.1e18);
        assertEq(token.balanceOf(address(treasury)), 15.9e18 + 23e18);
        assertEq(token.balanceOf(address(garden)), 17e18);
        _assertAccounting(53);
    }

    function testFuzz_interleavedPurchasersPaginateWithoutLossOrDuplicatePositions(
        uint8 quantitySeed,
        uint8 pageSeed
    ) public {
        uint256 quantity = bound(quantitySeed, 1, 50);
        uint256 limit = bound(pageSeed, 1, 100);
        vm.startPrank(bob);
        token.approve(address(garden), quantity * 1e18);
        garden.buyCandles(quantity, 6);
        vm.stopPrank();
        _buy(50, 1, "last batch");
        uint256 cursor = PREFIX + 1;
        uint256 end = PREFIX + quantity + 54;
        uint256 seen;
        while (cursor < end) {
            (WishGarden.Candle[] memory records, uint256 next) = garden.getCandles(cursor, limit);
            assertGt(records.length, 0);
            assertLe(records.length, limit);
            assertEq(next, cursor + records.length);
            for (uint256 i; i < records.length; ++i) {
                uint256 sequence = cursor + i - PREFIX;
                assertEq(records[i].position, PREFIX + sequence - 1);
                assertEq(records[i].purchaser, sequence <= 3 || sequence > quantity + 3 ? alice : bob);
                assertFalse(records[i].freeClaim);
                ++seen;
            }
            cursor = next;
        }
        assertEq(seen, quantity + 53);
        (WishGarden.Candle[] memory empty, uint256 nextId) = garden.getCandles(end, 100);
        assertEq(empty.length, 0);
        assertEq(nextId, end);
        uint256 offset;
        while (offset < 53) {
            (uint256[] memory ids, uint256 next) = garden.candleIdsOf(alice, offset, limit);
            for (uint256 i; i < ids.length; ++i) {
                uint256 index = offset + i;
                assertEq(ids[i], PREFIX + index + 1 + (index < 3 ? 0 : quantity));
            }
            assertGt(next, offset);
            offset = next;
        }
        assertEq(offset, 53);
        assertEq(garden.candleCountOf(bob), quantity);
    }

    function _withdraw(uint8 bucket, address destination, uint256 amount) private {
        if (bucket == 0) treasury.withdrawEcosystem(destination, amount);
        else if (bucket == 1) treasury.withdrawOperations(destination, amount);
        else treasury.withdrawFounder(destination, amount);
    }

    function _financialState() private view returns (bytes32) {
        bytes32 custody = keccak256(
            abi.encode(
                token.balanceOf(alice),
                token.balanceOf(bob),
                token.balanceOf(address(garden)),
                token.balanceOf(address(treasury)),
                token.totalSupply(),
                token.allowance(alice, address(garden))
            )
        );
        bytes32 allocations = keccak256(
            abi.encode(
                treasury.ecosystemBalance(),
                treasury.operationsBalance(),
                treasury.founderBalance(),
                treasury.totalEcosystemWithdrawn(),
                treasury.totalOperationsWithdrawn(),
                treasury.totalFounderWithdrawn()
            )
        );
        return keccak256(
            abi.encode(
                custody,
                allocations,
                treasury.totalPayments(),
                treasury.pendingBurn(),
                treasury.inTransitBurn(),
                treasury.confirmedBurn(),
                treasury.totalBurnAllocated(),
                garden.totalCandles(),
                garden.paidCandles()
            )
        );
    }
}
