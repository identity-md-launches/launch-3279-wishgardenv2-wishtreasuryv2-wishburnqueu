// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReplacementTestBase} from "./ReplacementTestBase.sol";
import {IMDBurnQueue} from "../../src/bridge/IMDBurnQueue.sol";
import {Origin} from "../../src/bridge/IMDBridgeInterfaces.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WalletGas} from "../helpers/WalletGas.sol";

contract BridgeTest is ReplacementTestBase, WalletGas {
    function test_endToEndMockedDelayedCreditBurnAndAcknowledgement() public {
        _buy(10, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(3e18);
        assertEq(treasury.pendingBurn(), 0);
        assertEq(treasury.inTransitBurn(), 3e18);
        assertEq(treasury.confirmedBurn(), 0);
        assertEq(token.lastRecipient(), bytes32(uint256(uint160(address(receiver)))));
        assertEq(token.allowance(address(treasury), IMD), 0);
        assertEq(token.refund(), address(this));
        vm.warp(block.timestamp + 30 days);
        assertEq(treasury.inTransitBurn(), 3e18);
        _burn(id, guid, 3e18);
        assertEq(baseToken.balanceOf(address(receiver)), 0);
        assertEq(baseToken.totalSupply(), 0);
        assertEq(receiver.totalBurned(), 3e18);
        assertEq(treasury.confirmedBurn(), 0);
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        bytes memory ack = baseEndpoint.lastMessage();
        _deliverAck(ack);
        assertEq(treasury.confirmedBurn(), 3e18);
        assertEq(treasury.inTransitBurn(), 0);
        _deliverAck(ack);
        assertEq(treasury.confirmedBurn(), 3e18);
        _assertAccounting(10);
    }

    function test_dustRetainedAndCombinedIntoLaterBatch() public {
        _buy(2, 0, "");
        uint256 requested = 0.3e18 + 17;
        (uint256 rounded, uint256 dust, uint256 fee, uint256 next) = treasury.quoteDispatch(requested);
        assertEq(rounded, 0.3e18);
        assertEq(dust, 17);
        assertEq(fee, 0.001 ether);
        assertEq(next, 1);
        _dispatch(requested);
        assertEq(treasury.pendingBurn(), 0.3e18);
        // A partial split below one candle's share is refused unless it is everything that is left.
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(0.3e18 - 1, 2);
        assertEq(treasury.pendingBurn(), 0.3e18);
        // Over-asking is clamped to the whole rounded remainder; the dust in the event is what was unsendable.
        (rounded, dust,, next) = treasury.quoteDispatch(5e18);
        assertEq(rounded, 0.3e18);
        assertEq(dust, 0);
        assertEq(next, 2);
        _dispatch(5e18);
        assertEq(treasury.pendingBurn(), 0);
        _assertAccounting(2);
    }

    /// @notice Reopened low finding: a third party can no longer split pending funds into micro-batches or
    ///         invalidate a prepared dispatch with a front-run; the prepared one still sends what is left.
    function test_microBatchFrontRunCannotRevertOperatorDispatchOrInflateBatches() public {
        _buy(10, 0, "");
        (uint256 amount,, uint256 fee, uint256 next) = treasury.quoteDispatch(3e18);
        assertEq(amount, 3e18);
        assertEq(next, 1);
        vm.prank(bob);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: fee}(1e12, 1);
        vm.prank(bob);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: fee}(0.3e18 - 1e12, 1);
        assertEq(treasury.batchCount(), 0);
        // The smallest batch anyone can split off is one candle's share and costs them the native fee.
        vm.prank(bob);
        assertEq(treasury.dispatch{value: fee}(0.3e18, 1), 1);
        // The operator's prepared call (quoted for batch 1) still succeeds as batch 2 with the remainder.
        assertEq(treasury.dispatch{value: fee}(3e18, 1 + 1), 2);
        (, uint256 recorded,) = treasury.batches(2);
        assertEq(recorded, 2.7e18);
        assertEq(treasury.pendingBurn(), 0);
        assertEq(treasury.inTransitBurn(), 3e18);
        // Nothing left: a further dispatch reverts instead of creating empty batches.
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: fee}(3e18, 3);
        // A stale upper bound (someone already used this batch id) reverts rather than sending unexpectedly.
        _buy(1, 0, "");
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: fee}(0.3e18, 2);
        assertEq(treasury.batchCount(), 2);
        _assertAccounting(11);
    }

    function test_wholeRemainderBelowMinimumIsStillDispatchable() public {
        _buy(1, 0, "");
        vm.prank(bob);
        treasury.dispatch{value: 0.001 ether}(0.3e18, 1);
        _buy(1, 0, "");
        // Operator chooses an unusual size: 0.3e18 pending, request 0.2e18 is refused (not whole, below min).
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(0.2e18, 2);
        assertEq(treasury.MIN_DISPATCH(), 0.3e18);
        _dispatch(0.3e18);
        assertEq(treasury.pendingBurn(), 0);
        _assertAccounting(2);
    }

    /// @notice Reopened medium finding: the receiver cannot be an owner-named wallet. Even if a wallet could
    ///         speak through the endpoint from Base, its READY/BURNED messages never authenticate, and
    ///         dispatch only ever sends to the derived receiver address.
    function test_eoaCannotBecomeReceiverCollectBurnFundsOrForgeConfirmation() public {
        address eoa = 0x0000000000000000000000000000000000000Bad;
        _buy(10, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(3e18);
        assertEq(token.lastRecipient(), bytes32(uint256(uint160(address(receiver)))));
        assertTrue(token.lastRecipient() != bytes32(uint256(uint160(eoa))));
        bytes memory burned = abi.encode(uint8(2), id, guid, uint256(3e18));
        vm.expectRevert(IMDBurnQueue.UnauthenticatedMessage.selector);
        _deliverFrom(eoa, burned);
        vm.expectRevert(IMDBurnQueue.UnauthenticatedMessage.selector);
        _deliverFrom(OWNER, burned);
        assertEq(treasury.confirmedBurn(), 0);
        assertEq(treasury.inTransitBurn(), 3e18);
        // Only the derived receiver, after an actual exact burn, confirms.
        _burn(id, guid, 3e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        _deliverAck(baseEndpoint.lastMessage());
        assertEq(treasury.confirmedBurn(), 3e18);
    }

    /// @notice Reopened low finding: readiness refuses while the Base token would reject a credit. The bound is
    ///         the frozen maximum batch, and held IMD is burned first so it cannot use up the headroom.
    function test_readinessRefusedWhileBlacklistedOrMaxWalletBelowMaximumBatch() public {
        vm.chainId(8453);
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        BaseBurnReceiver fresh = _deployReceiver(address(t), keccak256("restricted"));
        baseToken.setBlacklisted(address(fresh), true);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        fresh.sendAcknowledgement{value: 0.001 ether}(0);
        baseToken.setBlacklisted(address(fresh), false);
        baseToken.setBlacklisted(address(adapter), true);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        fresh.sendAcknowledgement{value: 0.001 ether}(0);
        baseToken.setBlacklisted(address(adapter), false);
        baseToken.setLimits(true, MAX_BATCH - 1);
        assertEq(fresh.maxCredit(), MAX_BATCH - 1);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        fresh.sendAcknowledgement{value: 0.001 ether}(0);
        baseToken.setLimits(true, MAX_BATCH);
        baseToken.mint(address(fresh), 0.5e18);
        assertEq(fresh.maxCredit(), MAX_BATCH - 0.5e18);
        fresh.sendAcknowledgement{value: 0.001 ether}(0);
        assertEq(baseToken.balanceOf(address(fresh)), 0, "held IMD is burned before the headroom check");
        assertEq(fresh.surplusBurned(), 0.5e18);
        assertEq(fresh.maxCredit(), MAX_BATCH);
        baseToken.setLimits(true, 1);
        baseToken.setExcluded(address(fresh), true);
        assertEq(fresh.maxCredit(), type(uint256).max);
        baseToken.setExcluded(address(fresh), false);
        baseToken.setLimits(false, 0);
        assertEq(fresh.maxCredit(), type(uint256).max);
        assertEq(fresh.MIN_CREDIT(), treasury.MIN_DISPATCH());
        assertEq(receiver.maxBatch(), treasury.maxBatch());
        assertEq(treasury.maxBatch(), MAX_BATCH);
    }

    /// @notice Reopened low finding: while limits are on and trading is off the token rejects adapter credits
    ///         unless the adapter or the receiver is fee-excluded, so readiness is refused in that state.
    function test_readinessRefusedWhileTradingInactive() public {
        vm.chainId(8453);
        baseToken.setTradingPaused(true);
        assertEq(receiver.maxCredit(), type(uint256).max, "limits off: trading flag is not consulted");
        baseToken.setLimits(true, MAX_BATCH);
        assertEq(receiver.maxCredit(), 0);
        vm.expectRevert(BaseBurnReceiver.CreditRestricted.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        baseToken.setExcludedFromFees(address(adapter), true);
        assertEq(receiver.maxCredit(), MAX_BATCH);
        baseToken.setExcludedFromFees(address(adapter), false);
        baseToken.setExcludedFromFees(address(receiver), true);
        assertEq(receiver.maxCredit(), MAX_BATCH);
        baseToken.setExcludedFromFees(address(receiver), false);
        baseToken.setTradingPaused(false);
        assertEq(receiver.maxCredit(), MAX_BATCH);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
    }

    /// @notice Reopened medium finding: no caller can create a batch above the frozen bound; a larger pending
    ///         balance is sent as several batches, each one the receiver proved it can accept.
    function test_dispatchNeverExceedsFrozenMaximumBatch() public {
        _buy(50, 0, "");
        _buy(50, 0, "");
        _buy(50, 0, "");
        assertEq(treasury.pendingBurn(), 45e18);
        (uint256 amount, uint256 dust,, uint256 next) = treasury.quoteDispatch(type(uint256).max);
        assertEq(amount, MAX_BATCH);
        assertEq(dust, 0);
        assertEq(next, 1);
        vm.prank(bob);
        assertEq(treasury.dispatch{value: 0.001 ether}(type(uint256).max, type(uint256).max), 1);
        (, uint256 recorded,) = treasury.batches(1);
        assertEq(recorded, MAX_BATCH);
        assertEq(token.lastAmount(), MAX_BATCH);
        assertEq(treasury.pendingBurn(), 15e18);
        assertEq(treasury.inTransitBurn(), MAX_BATCH);
        vm.prank(bob);
        treasury.dispatch{value: 0.001 ether}(40e18, 2);
        (, recorded,) = treasury.batches(2);
        assertEq(recorded, 15e18);
        assertEq(treasury.pendingBurn(), 0);
        _assertAccounting(150);
    }

    function testFuzz_dispatchBoundedByRequestPendingAndFrozenMaximum(uint8 buys, uint256 requested) public {
        uint256 count = bound(buys, 1, 4);
        for (uint256 i; i < count; ++i) {
            _buy(50, 0, "");
        }
        uint256 pending = count * 15e18;
        requested = bound(requested, 0.3e18, type(uint256).max);
        uint256 expected = requested < pending ? requested : pending;
        if (expected > MAX_BATCH) expected = MAX_BATCH;
        expected = expected / 1e12 * 1e12;
        uint256 id = treasury.dispatch{value: 0.001 ether}(requested, 1);
        (, uint256 recorded,) = treasury.batches(id);
        assertEq(recorded, expected);
        assertLe(recorded, treasury.maxBatch());
        assertEq(treasury.pendingBurn(), pending - expected);
        _assertAccounting(count * 50);
    }

    function test_freezeRejectsUnusableMaximumBatch() public {
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        vm.startPrank(OWNER);
        uint256[4] memory bad = [uint256(0), 0.3e18 - 1e12, 1e18 + 1, (uint256(type(uint64).max) + 1) * 1e12];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
            t.freezeBridge(
                address(ethEndpoint),
                address(baseEndpoint),
                address(adapter),
                GAS,
                GAS,
                GAS,
                bad[i],
                SALT,
                EVIDENCE
            );
        }
        t.freezeBridge(
            address(ethEndpoint),
            address(baseEndpoint),
            address(adapter),
            GAS,
            GAS,
            GAS,
            0.3e18,
            SALT,
            EVIDENCE
        );
        vm.stopPrank();
        assertEq(t.maxBatch(), 0.3e18);
        // The bound is part of the receiver derivation: a receiver built for another bound is another address.
        assertTrue(
            t.baseReceiver()
                != t.predictReceiver(address(baseEndpoint), address(adapter), GAS, MAX_BATCH, SALT)
        );
        vm.chainId(8453);
        vm.expectRevert(BaseBurnReceiver.InvalidConfiguration.selector);
        new BaseBurnReceiver(
            address(baseEndpoint), address(adapter), address(t), 30101, 30184, GAS, 0.3e18 - 1
        );
    }

    /// @notice Reopened medium finding: IMD sent straight to the receiver is no longer stuck there. Anyone can
    ///         burn it (a real supply burn), it is never counted as a batch, and it cannot leave any other way.
    function test_donationIsBurnableSurplusNeverCountedAsBatch() public {
        vm.chainId(8453);
        vm.expectRevert(BaseBurnReceiver.InexactBurn.selector);
        receiver.burnSurplus();
        baseToken.mint(address(receiver), 7e18);
        uint256 supply = baseToken.totalSupply();
        vm.chainId(1);
        vm.expectRevert(BaseBurnReceiver.WrongChain.selector);
        receiver.burnSurplus();
        vm.chainId(8453);
        vm.prank(bob);
        assertEq(receiver.burnSurplus(), 7e18);
        assertEq(baseToken.balanceOf(address(receiver)), 0);
        assertEq(baseToken.totalSupply(), supply - 7e18);
        assertEq(receiver.surplusBurned(), 7e18);
        assertEq(receiver.totalBurned(), 0);
        vm.expectRevert(BaseBurnReceiver.UnknownBatch.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(1);
        // A later real batch burns its own credit; the donation stays unattributed.
        vm.chainId(1);
        _buy(1, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        _burn(id, guid, 0.3e18);
        assertEq(receiver.totalBurned(), 0.3e18);
        assertEq(receiver.surplusBurned(), 7e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        _deliverAck(baseEndpoint.lastMessage());
        assertEq(treasury.confirmedBurn(), 0.3e18);
        _assertAccounting(1);
    }

    /// @notice Burning a batch credit with `burnSurplus` before its compose runs cannot strand the batch or
    ///         count it twice: the compose completes from the remembered amount, exactly once.
    function testFuzz_surplusBurnBeforeComposeCompletesBatchExactlyOnce(uint64 donated, uint64 sweptPart)
        public
    {
        _buy(10, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(3e18);
        vm.chainId(8453);
        uint256 donation = bound(donated, 0, 5e18);
        uint256 early = bound(sweptPart, 0, 3e18);
        // Part of the credit and a donation are present when someone burns the surplus.
        baseToken.mint(address(receiver), donation + early);
        if (donation + early != 0) receiver.burnSurplus();
        // The rest of the credit arrives with the compose.
        baseToken.mint(address(receiver), 3e18 - early);
        uint256 supply = baseToken.totalSupply();
        vm.prank(address(baseEndpoint));
        receiver.lzCompose(address(adapter), guid, _composeMessage(id, 3e18), alice, "");
        assertEq(receiver.totalBurned(), 3e18);
        assertEq(receiver.surplusBurned(), donation, "only the donation stays unattributed");
        assertEq(baseToken.balanceOf(address(receiver)), 0);
        assertEq(baseToken.totalSupply(), supply - (3e18 - early));
        vm.prank(address(baseEndpoint));
        vm.expectRevert(BaseBurnReceiver.DuplicateBurn.selector);
        receiver.lzCompose(address(adapter), guid, _composeMessage(id, 3e18), alice, "");
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        _deliverAck(baseEndpoint.lastMessage());
        assertEq(treasury.confirmedBurn(), 3e18);
        assertEq(treasury.inTransitBurn(), 0);
    }

    function test_composeWithoutCreditOrSurplusStillReverts() public {
        _buy(2, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.6e18);
        vm.chainId(8453);
        baseToken.mint(address(receiver), 0.2e18);
        receiver.burnSurplus();
        baseToken.mint(address(receiver), 0.3e18);
        // 0.2 already burned + 0.3 held < 0.6 credited: nothing is consumed and the exact retry stays open.
        vm.prank(address(baseEndpoint));
        vm.expectRevert(BaseBurnReceiver.InexactBurn.selector);
        receiver.lzCompose(address(adapter), guid, _composeMessage(id, 0.6e18), alice, "");
        assertEq(receiver.surplusBurned(), 0.2e18);
        assertEq(receiver.totalBurned(), 0);
        assertEq(baseToken.balanceOf(address(receiver)), 0.3e18);
        baseToken.mint(address(receiver), 0.1e18);
        vm.prank(address(baseEndpoint));
        receiver.lzCompose(address(adapter), guid, _composeMessage(id, 0.6e18), alice, "");
        assertEq(receiver.surplusBurned(), 0);
        assertEq(receiver.totalBurned(), 0.6e18);
    }

    function testFuzz_sendFailureRetryNeverDoubleCounts(uint8 modeSeed, uint8 q) public {
        uint256 quantity = bound(q, 1, 50);
        _buy(quantity, 0, "");
        uint256 amount = quantity * 0.3e18;
        uint8 mode = uint8(bound(modeSeed, 1, 3));
        if (mode == 3) mode = 4;
        token.setSendMode(mode);
        vm.expectRevert();
        treasury.dispatch{value: 0.001 ether}(amount, 1);
        assertEq(treasury.pendingBurn(), amount);
        assertEq(treasury.inTransitBurn(), 0);
        assertEq(treasury.batchCount(), 0);
        token.setSendMode(0);
        _dispatch(amount);
        assertEq(treasury.inTransitBurn(), amount);
        assertEq(treasury.batchCount(), 1);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(amount, 1);
        _assertAccounting(quantity);
    }

    function test_feeStaleBatchZeroDustAndOverPendingReject() public {
        _buy(1, 0, "");
        vm.expectRevert(IMDBurnQueue.IncorrectNativeFee.selector);
        treasury.dispatch{value: 0.002 ether}(0.3e18, 1);
        vm.expectRevert(IMDBurnQueue.IncorrectNativeFee.selector);
        treasury.dispatch(0.3e18, 1);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(0.3e18, 0);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(1, 1);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(0, 1);
        assertEq(treasury.batchCount(), 0);
        // Asking for more than pending sends the whole rounded pending balance, never more.
        treasury.dispatch{value: 0.001 ether}(1e18, 1);
        (, uint256 recorded,) = treasury.batches(1);
        assertEq(recorded, 0.3e18);
        assertEq(treasury.pendingBurn(), 0);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(1e18, 2);
        _assertAccounting(1);
    }

    function test_badOrReusedGuidCannotConsumePending() public {
        _buy(2, 0, "");
        token.setSendMode(5);
        _dispatch(0.3e18);
        vm.expectRevert(IMDBurnQueue.InvalidBridgeReceipt.selector);
        treasury.dispatch{value: 0.001 ether}(0.3e18, 2);
        assertEq(treasury.pendingBurn(), 0.3e18);
        assertEq(treasury.batchCount(), 1);
    }

    function test_unauthenticatedOrMismatchedAcknowledgementsCannotConfirm() public {
        _buy(1, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        bytes memory ack = abi.encode(uint8(2), id, guid, uint256(0.3e18));
        Origin memory origin = Origin(30184, bytes32(uint256(uint160(address(receiver)))), 1);
        vm.expectRevert(IMDBurnQueue.UnauthenticatedMessage.selector);
        treasury.lzReceive(origin, guid, ack, alice, "");
        origin.srcEid = 30101;
        vm.prank(address(ethEndpoint));
        vm.expectRevert();
        treasury.lzReceive(origin, guid, ack, alice, "");
        origin.srcEid = 30184;
        origin.sender = bytes32(uint256(uint160(alice)));
        vm.prank(address(ethEndpoint));
        vm.expectRevert();
        treasury.lzReceive(origin, guid, ack, alice, "");
        vm.expectRevert();
        _deliverAck(abi.encode(uint8(2), id, guid, uint256(0.3e18 + 1)));
        vm.expectRevert();
        _deliverAck(abi.encode(uint8(2), id + 1, guid, uint256(0.3e18)));
        vm.expectRevert();
        _deliverAck(abi.encode(uint8(2), id, bytes32(uint256(9)), uint256(0.3e18)));
        assertEq(treasury.confirmedBurn(), 0);
    }

    function test_endpointCreditShortageRetryAndDuplicateCompose() public {
        _buy(1, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        vm.chainId(8453);
        bytes memory message = _composeMessage(id, 0.3e18);
        vm.prank(address(baseEndpoint));
        vm.expectRevert(BaseBurnReceiver.InexactBurn.selector);
        receiver.lzCompose(address(adapter), guid, message, alice, "");
        assertFalse(receiver.consumedGuid(guid));
        _burn(id, guid, 0.3e18);
        vm.prank(address(baseEndpoint));
        vm.expectRevert(BaseBurnReceiver.DuplicateBurn.selector);
        receiver.lzCompose(address(adapter), guid, message, alice, "");
        assertEq(receiver.totalBurned(), 0.3e18);
    }

    function testFuzz_falseBurnOrNondecreasingSupplyRollsBackConsumption(uint8 seed) public {
        uint8 mode = uint8(bound(seed, 1, 3));
        vm.chainId(8453);
        baseToken.mint(address(receiver), 1e18);
        baseToken.setBurnMode(mode);
        bytes32 guid = keccak256("failed burn");
        vm.prank(address(baseEndpoint));
        vm.expectRevert();
        receiver.lzCompose(address(adapter), guid, _composeMessage(1, 1e18), alice, "");
        assertFalse(receiver.consumedGuid(guid));
        assertEq(receiver.totalBurned(), 0);
        assertEq(baseToken.balanceOf(address(receiver)), 1e18);
        baseToken.setBurnMode(0);
        vm.prank(address(baseEndpoint));
        receiver.lzCompose(address(adapter), guid, _composeMessage(1, 1e18), alice, "");
        assertEq(receiver.totalBurned(), 1e18);
    }

    function test_wrongEndpointAdapterSourceSenderAndPayloadRejected() public {
        vm.chainId(8453);
        bytes32 guid = keccak256("authenticated");
        bytes memory message = _composeMessage(1, 1e18);
        vm.expectRevert();
        receiver.lzCompose(address(adapter), guid, message, alice, "");
        vm.prank(address(baseEndpoint));
        vm.expectRevert();
        receiver.lzCompose(alice, guid, message, alice, "");
        bytes memory wrong = abi.encodePacked(
            uint64(1),
            uint32(30102),
            uint256(1e18),
            bytes32(uint256(uint160(address(treasury)))),
            abi.encode(uint256(1), uint256(1), uint256(1e18))
        );
        vm.prank(address(baseEndpoint));
        vm.expectRevert();
        receiver.lzCompose(address(adapter), guid, wrong, alice, "");
        wrong = abi.encodePacked(
            uint64(1),
            uint32(30101),
            uint256(1e18),
            bytes32(uint256(uint160(alice))),
            abi.encode(uint256(1), uint256(1), uint256(1e18))
        );
        vm.prank(address(baseEndpoint));
        vm.expectRevert();
        receiver.lzCompose(address(adapter), guid, wrong, alice, "");
        vm.prank(address(baseEndpoint));
        vm.expectRevert();
        receiver.lzCompose(address(adapter), guid, hex"00", alice, "");
        assertEq(receiver.totalBurned(), 0);
    }

    function test_ackFailureRetryDoesNotRepeatBurnAndNoUnburnedAcknowledgement() public {
        _buy(1, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        _burn(id, guid, 0.3e18);
        vm.expectRevert(BaseBurnReceiver.UnknownBatch.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(id + 1);
        baseEndpoint.setFail(true);
        vm.expectRevert();
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        assertEq(receiver.totalBurned(), 0.3e18);
        baseEndpoint.setFail(false);
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        _deliverAck(baseEndpoint.lastMessage());
        vm.chainId(8453);
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        _deliverAck(baseEndpoint.lastMessage());
        _assertAccounting(1);
        assertEq(treasury.confirmedBurn(), 0.3e18);
    }

    function test_outOfOrderBatchReceiptsAndNoPrivilegedBaseEscape() public {
        _buy(2, 0, "");
        (uint256 one, bytes32 g1) = _dispatch(0.3e18);
        (uint256 two, bytes32 g2) = _dispatch(0.3e18);
        _burn(two, g2, 0.3e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(two);
        _deliverAck(baseEndpoint.lastMessage());
        _burn(one, g1, 0.3e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(one);
        _deliverAck(baseEndpoint.lastMessage());
        assertEq(treasury.confirmedBurn(), 0.6e18);
        vm.prank(OWNER);
        (bool ok,) = address(receiver).call(abi.encodeWithSignature("withdraw(address,uint256)", OWNER, 1));
        assertFalse(ok);
        vm.prank(OWNER);
        (ok,) = address(receiver).call(abi.encodeWithSignature("approve(address,uint256)", OWNER, 1));
        assertFalse(ok);
    }

    function test_changedOfficialPeerStopsPurchasesAndDispatch() public {
        _buy(1, 0, "");
        token.setPeer(bob);
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        treasury.dispatch{value: 0.001 ether}(0.3e18, 1);
        vm.prank(alice);
        token.approve(address(garden), 1e18);
        vm.prank(alice);
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        garden.buyCandlesWithWish(1, 0, "rollback", true);
        _assertAccounting(1);
    }

    function test_endpointRuntimeChangeCannotAuthenticateBurn() public {
        _buy(1, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        bytes memory ack = abi.encode(uint8(2), id, guid, uint256(0.3e18));
        vm.etch(address(ethEndpoint), hex"00");
        vm.expectRevert(IMDBurnQueue.UnauthenticatedMessage.selector);
        _deliverAck(ack);
        assertEq(treasury.confirmedBurn(), 0);
    }

    function test_dispatchAndComposeAtWalletGasDoAllWork() public {
        _buy(1, 0, "");
        assertSameAtWalletGas(
            alice, address(treasury), 0.001 ether, abi.encodeCall(treasury.dispatch, (0.3e18, 1))
        );
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        vm.chainId(8453);
        baseToken.mint(address(receiver), 0.3e18);
        assertSameAtWalletGas(
            address(baseEndpoint),
            address(receiver),
            abi.encodeCall(
                receiver.lzCompose, (address(adapter), guid, _composeMessage(id, 0.3e18), alice, bytes(""))
            )
        );
    }
}
