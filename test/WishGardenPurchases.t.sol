// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GardenTestBase} from "./helpers/GardenTestBase.sol";
import {GardenEconomy} from "../src/GardenEconomy.sol";
import {LegacyWishGarden as WishGarden} from "./legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "./legacy-src/LegacyWishGardenTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract WishGardenPurchasesTest is GardenTestBase {
    function test_oneCandleExactPriceSplitEventsAndRecord() public {
        uint256 supply = token.totalSupply();
        uint256 beforeBuyer = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(garden), 1e18);
        vm.expectEmit(true, true, false, true, address(garden));
        emit WishGarden.CandleCreated(1, alice, 0, 2, uint64(block.timestamp), false, 0);
        vm.expectEmit(true, true, false, true, address(treasury));
        emit WishGardenTreasury.PaymentAllocated(alice, 1, 1, 1e18, 0.3e18, 0.5e18, 0.1e18, 0.1e18);
        vm.expectEmit(true, true, false, true, address(garden));
        emit WishGarden.CandlesPurchased(alice, 1, 1, 2, 1e18);
        vm.prank(alice);
        assertEq(garden.buyCandles(1, 2), 1);
        assertEq(token.balanceOf(alice), beforeBuyer - 1e18);
        assertEq(token.totalSupply(), supply, "locking is not a supply burn");
        assertEq(token.allowance(alice, address(garden)), 0);
        WishGarden.Candle memory candle = garden.getCandle(1);
        assertEq(candle.purchaser, alice);
        assertEq(candle.style, 2);
        assertEq(candle.position, 0);
        assertEq(candle.createdAt, block.timestamp);
        assertFalse(candle.freeClaim);
        assertEq(garden.totalCandles(), 1);
        assertEq(garden.paidCandles(), 1);
        assertEq(garden.freeCandles(), 0);
        _assertAccounting(1);
    }

    function test_tenCandlesCostTenAndHaveUniqueStablePositions() public {
        uint256 beforeBuyer = token.balanceOf(alice);
        assertEq(_buy(alice, 10, 6), 1);
        assertEq(token.balanceOf(alice), beforeBuyer - 10e18);
        for (uint256 i = 1; i <= 10; ++i) {
            WishGarden.Candle memory candle = garden.getCandle(i);
            assertEq(candle.position, i - 1);
            assertEq(candle.style, 6);
            assertEq(candle.purchaser, alice);
        }
        _assertAccounting(10);
    }

    function test_allSevenStylesHaveIdenticalPriceAndPermanentRecords() public {
        for (uint8 style; style < 7; ++style) {
            assertEq(_buy(alice, 1, style), uint256(style) + 1);
        }
        WishGarden.Candle memory original = garden.getCandle(1);
        vm.warp(block.timestamp + 3650 days);
        _buy(bob, 50, 1);
        WishGarden.Candle memory later = garden.getCandle(1);
        assertEq(abi.encode(original), abi.encode(later));
        assertEq(garden.candleCountOf(alice), 7);
        assertEq(garden.candleCountOf(bob), 50);
        _assertAccounting(57);
    }

    function test_moreThanTenThousandCandlesWithoutCap() public {
        for (uint256 i; i < 200; ++i) {
            _buy(alice, 50, 0);
        }
        assertEq(_buy(bob, 1, 1), 10_001);
        assertEq(garden.totalCandles(), 10_001);
        assertEq(garden.getCandle(1).position, 0);
        assertEq(garden.getCandle(10_001).position, 10_000);
        assertEq(garden.getCandle(10_001).purchaser, bob);
        _assertAccounting(10_001);
    }

    function test_zeroAndOversizedQuantitiesRevertWithoutStateChange() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 0));
        garden.buyCandles(0, 0);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 51));
        garden.buyCandles(51, 0);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, type(uint256).max));
        garden.buyCandles(type(uint256).max, 0);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
        _assertAccounting(0);
    }

    function test_badStyleRejectedBeforePayment() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.InvalidStyle.selector, 7));
        garden.buyCandles(1, 7);
        assertEq(garden.totalCandles(), 0);
        _assertAccounting(0);
    }

    function test_insufficientAllowanceRollsBackAllRecordsAndAccounting() public {
        vm.startPrank(alice);
        token.approve(address(garden), 1e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(garden), 1e18 - 1, 1e18
            )
        );
        garden.buyCandles(1, 0);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
        assertEq(garden.candleCountOf(alice), 0);
        _assertAccounting(0);
    }

    function test_insufficientBalanceRevertsAndPreservesAllowance() public {
        deal(IMD, alice, 1e18 - 1, true);
        vm.startPrank(alice);
        token.approve(address(garden), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18 - 1, 1e18)
        );
        garden.buyCandles(1, 0);
        vm.stopPrank();
        assertEq(token.allowance(alice, address(garden)), 1e18);
        assertEq(garden.totalCandles(), 0);
        _assertAccounting(0);
    }

    function test_callersCannotSpendAnotherWalletsApproval() public {
        vm.prank(alice);
        token.approve(address(garden), 10e18);
        vm.prank(bob);
        vm.expectRevert();
        garden.buyCandles(10, 0);
        assertEq(token.allowance(alice, address(garden)), 10e18);
        assertEq(garden.totalCandles(), 0);
    }

    function test_pendingTreasurySetupPreventsPurchase() public {
        WishGardenTreasury pending = new WishGardenTreasury(OWNER, address(sink), operations, founder);
        WishGarden pendingGarden = new WishGarden(OWNER, address(pending));
        vm.prank(alice);
        vm.expectRevert(WishGarden.TreasuryNotConfigured.selector);
        pendingGarden.buyCandles(1, 0);
        assertEq(pendingGarden.totalCandles(), 0);
    }

    function test_wrongChainMissingTokenAndWrongDecimalsFailClosed() public {
        vm.chainId(10);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.WrongChain.selector, 10));
        garden.buyCandles(1, 0);
        vm.chainId(1);
        vm.mockCall(IMD, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.UnexpectedIMDDecimals.selector, 6));
        garden.buyCandles(1, 0);
        vm.clearMockedCalls();
        vm.etch(IMD, "");
        vm.expectRevert(GardenEconomy.IMDUnavailable.selector);
        garden.buyCandles(1, 0);
        assertEq(garden.totalCandles(), 0);
    }

    function test_nativeETHCannotPayForCandlesOrBeDeposited() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        (bool purchaseSuccess,) = address(garden).call{value: 1}(abi.encodeCall(garden.buyCandles, (1, 0)));
        (bool depositSuccess,) = address(garden).call{value: 1}("");
        (bool treasurySuccess,) = address(treasury).call{value: 1}("");
        (bool sinkSuccess,) = address(sink).call{value: 1}("");
        vm.stopPrank();
        assertFalse(purchaseSuccess);
        assertFalse(depositSuccess);
        assertFalse(treasurySuccess);
        assertFalse(sinkSuccess);
        assertEq(garden.totalCandles(), 0);
    }

    function test_paginationAndHistorySurviveLaterPurchases() public {
        _buy(alice, 3, 0);
        _buy(bob, 2, 1);
        _buy(alice, 2, 2);
        (uint256[] memory ids, uint256 next) = garden.candleIdsOf(alice, 0, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[2], 3);
        assertEq(next, 3);
        (ids, next) = garden.candleIdsOf(alice, next, 100);
        assertEq(ids.length, 2);
        assertEq(ids[0], 6);
        assertEq(ids[1], 7);
        assertEq(next, 5);
        (ids, next) = garden.candleIdsOf(alice, next, 100);
        assertEq(ids.length, 0);
        assertEq(next, 5);
        (WishGarden.Candle[] memory records, uint256 nextId) = garden.getCandles(3, 3);
        assertEq(records.length, 3);
        assertEq(records[0].position, 2);
        assertEq(records[1].purchaser, bob);
        assertEq(nextId, 6);
        (records, nextId) = garden.getCandles(8, 100);
        assertEq(records.length, 0);
        assertEq(nextId, 8);
    }

    function test_emptyGardenAndInvalidPagesHaveUnambiguousResults() public {
        (WishGarden.Candle[] memory records, uint256 next) = garden.getCandles(1, 100);
        assertEq(records.length, 0);
        assertEq(next, 1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(0, 1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(2, 1);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.getCandles(1, 0);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.candleIdsOf(alice, 0, 101);
        vm.expectRevert(WishGarden.InvalidPage.selector);
        garden.candleIdsOf(alice, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.CandleNotFound.selector, 0));
        garden.getCandle(0);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.CandleNotFound.selector, 1));
        garden.getCandle(1);
    }

    function test_unsolicitedIMDDoesNotChangePriceOrAllocation() public {
        vm.startPrank(alice);
        token.transfer(address(treasury), 5e18);
        token.transfer(address(garden), 7e18);
        token.transfer(address(sink), 2e18);
        vm.stopPrank();
        _buy(bob, 10, 0);
        assertEq(treasury.totalPayments(), 10e18);
        assertEq(treasury.totalIMDLocked(), 3e18);
        assertEq(sink.lockedBalance(), 5e18);
        assertEq(treasury.unallocatedBalance(), 5e18);
        assertEq(token.balanceOf(address(garden)), 7e18);
        assertEq(treasury.accountedBalance(), 7e18);
    }

    function testFuzz_exactPaymentAndAllocation(uint8 quantitySeed, uint8 styleSeed) public {
        uint256 quantity = bound(uint256(quantitySeed), 1, 50);
        uint8 style = uint8(bound(uint256(styleSeed), 0, 6));
        uint256 balance = token.balanceOf(alice);
        uint256 supply = token.totalSupply();
        _buy(alice, quantity, style);
        assertEq(token.balanceOf(alice), balance - quantity * 1e18);
        assertEq(garden.totalCandles(), quantity);
        assertEq(token.totalSupply(), supply);
        assertEq(garden.getCandle(quantity).position, quantity - 1);
        _assertAccounting(quantity);
    }

    function test_maximumPurchaseBatchRemainsGasBounded() public {
        vm.startPrank(alice);
        token.approve(address(garden), 50e18);
        uint256 gasBefore = gasleft();
        garden.buyCandles(50, 0);
        uint256 used = gasBefore - gasleft();
        vm.stopPrank();
        emit log_named_uint("50 paid candles: call gas", used);
        assertLt(used, 8_000_000);
        assertEq(garden.paidCandles(), 50);
        _assertAccounting(50);
    }
}
