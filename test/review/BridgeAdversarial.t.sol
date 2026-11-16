// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReplacementTestBase} from "../replacement/ReplacementTestBase.sol";
import {WalletGas} from "../helpers/WalletGas.sol";
import {IMDBurnQueue} from "src/bridge/IMDBurnQueue.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {Origin, MessagingFee, MessagingReceipt, IBridgeEndpoint} from "src/bridge/IMDBridgeInterfaces.sol";

contract BridgeAdversarialTest is ReplacementTestBase, WalletGas {
    /// @dev Every invalid message has enough custody to burn; a missing validation cannot hide behind a shortage.
    function testFuzz_composeRejectsEveryMalformedFieldThenRetries(uint8 attackSeed, uint96 amountSeed)
        public
    {
        uint256 amount = bound(amountSeed, 1, 50e18);
        bytes32 guid = keccak256("adversarial compose");
        bytes memory message = _composeMessage(1, amount);
        address from = address(adapter);
        address caller = address(baseEndpoint);
        bytes4 error = BaseBurnReceiver.InvalidCompose.selector;
        uint256 value;
        uint8 attack = attackSeed % 14;
        vm.chainId(8453);
        baseToken.mint(address(receiver), amount);
        if (attack == 0) {
            message = bytes.concat(message, hex"00");
        } else if (attack == 1) {
            assembly ("memory-safe") { mstore(message, 171) }
        } else if (attack == 2) {
            _word(message, 76, 2); // version
        } else if (attack == 3) {
            _word(message, 108, 0); // batch ID
        } else if (attack == 4) {
            _word(message, 12, 0);
            _word(message, 140, 0);
        } else if (attack == 5) {
            _word(message, 140, amount + 1);
        } else if (attack == 6) {
            message[8] = 0xff;
            error = BaseBurnReceiver.UnauthenticatedCompose.selector;
        } else if (attack == 7) {
            message[44] = 0x01; // same low 160-bit address, noncanonical high bits
            error = BaseBurnReceiver.UnauthenticatedCompose.selector;
        } else if (attack == 8) {
            guid = bytes32(0);
        } else if (attack == 9) {
            from = alice;
            error = BaseBurnReceiver.UnauthenticatedCompose.selector;
        } else if (attack == 10) {
            caller = OWNER;
            error = BaseBurnReceiver.UnauthenticatedCompose.selector;
        } else if (attack == 11) {
            value = 1;
        } else if (attack == 12) {
            vm.chainId(1);
            error = BaseBurnReceiver.WrongChain.selector;
        } else {
            _word(message, 12, amount + 1); // credited amount differs from application amount
        }
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        vm.expectRevert(error);
        receiver.lzCompose{value: value}(from, guid, message, bob, "");
        assertEq(receiver.totalBurned(), 0);
        assertEq(baseToken.balanceOf(address(receiver)), amount);
        assertEq(baseToken.totalSupply(), amount);
        assertFalse(receiver.consumedGuid(keccak256("adversarial compose")));
        (, uint256 stored) = receiver.burns(1);
        assertEq(stored, 0);
        vm.chainId(8453);
        vm.prank(address(baseEndpoint));
        receiver.lzCompose(
            address(adapter), keccak256("adversarial compose"), _composeMessage(1, amount), bob, ""
        );
        assertEq(receiver.totalBurned(), amount);
        assertEq(baseToken.totalSupply(), 0);
    }

    function test_guidAndBatchReplayAreIndependentlyBlocked() public {
        _buy(3, 0, "");
        (uint256 one, bytes32 g1) = _dispatch(0.3e18);
        (uint256 two, bytes32 g2) = _dispatch(0.6e18);
        _burn(one, g1, 0.3e18);
        baseToken.mint(address(receiver), 0.6e18);
        vm.prank(address(baseEndpoint));
        vm.expectRevert(BaseBurnReceiver.DuplicateBurn.selector);
        receiver.lzCompose(address(adapter), g1, _composeMessage(two, 0.6e18), alice, "");
        vm.prank(address(baseEndpoint));
        vm.expectRevert(BaseBurnReceiver.DuplicateBurn.selector);
        receiver.lzCompose(address(adapter), g2, _composeMessage(one, 0.6e18), alice, "");
        assertFalse(receiver.consumedGuid(g2));
        assertEq(baseToken.balanceOf(address(receiver)), 0.6e18);
        vm.prank(address(baseEndpoint));
        receiver.lzCompose(address(adapter), g2, _composeMessage(two, 0.6e18), alice, "");
        assertEq(receiver.totalBurned(), 0.9e18);
        assertEq(baseToken.balanceOf(address(receiver)), 0);
    }

    function testFuzz_receiptRejectsMalformedPayloadEvenFromAuthenticatedSender(uint8 attackSeed) public {
        _buy(1, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        _burn(id, guid, 0.3e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        bytes memory original = baseEndpoint.lastMessage();
        bytes memory message = bytes.concat(original);
        uint8 attack = attackSeed % 9;
        uint256 value;
        if (attack == 0) {
            message = bytes.concat(message, hex"00");
        } else if (attack == 1) {
            assembly ("memory-safe") { mstore(message, 127) }
        } else if (attack == 2) {
            _word(message, 0, 3);
        } else if (attack == 3) {
            _word(message, 0, 256); // invalid ABI uint8
        } else if (attack == 4) {
            _word(message, 32, 0);
        } else if (attack == 5) {
            _word(message, 32, id + 1);
        } else if (attack == 6) {
            _word(message, 64, uint256(guid) ^ 1);
        } else if (attack == 7) {
            _word(message, 96, 0.3e18 - 1);
        } else {
            value = 1;
        }
        vm.chainId(1);
        vm.deal(address(ethEndpoint), 1 ether);
        vm.prank(address(ethEndpoint));
        vm.expectRevert();
        treasury.lzReceive{value: value}(_origin(), keccak256(message), message, alice, "");
        assertEq(treasury.inTransitBurn(), 0.3e18);
        assertEq(treasury.confirmedBurn(), 0);
        (,, bool confirmed) = treasury.batches(id);
        assertFalse(confirmed);
        _deliverAck(original);
        _deliverAck(original);
        assertEq(treasury.confirmedBurn(), 0.3e18);
        assertEq(treasury.inTransitBurn(), 0);
        assertEq(receiver.totalBurned(), 0.3e18);
    }

    function testFuzz_localDependencyDriftBlocksPaymentAndDispatchAtomically(uint8 fieldSeed) public {
        _buy(2, 0, "existing");
        uint8 field = fieldSeed % 10;
        address target = IMD;
        bytes memory callData;
        bytes memory result;
        if (field == 0) {
            callData = abi.encodeWithSignature("endpoint()");
            result = abi.encode(bob);
        } else if (field == 1) {
            callData = abi.encodeWithSignature("token()");
            result = abi.encode(bob);
        } else if (field == 2) {
            callData = abi.encodeWithSignature("approvalRequired()");
            result = abi.encode(true);
        } else if (field == 3) {
            callData = abi.encodeWithSignature("peers(uint32)", uint32(30184));
            result = abi.encode(bytes32(0));
        } else if (field == 4) {
            callData = abi.encodeWithSignature("decimalConversionRate()");
            result = abi.encode(uint256(1e6));
        } else if (field == 5) {
            callData = abi.encodeWithSignature("sharedDecimals()");
            result = abi.encode(uint8(18));
        } else if (field == 6) {
            callData = abi.encodeWithSignature("oftVersion()");
            result = abi.encode(bytes4(0), uint64(1));
        } else if (field == 7) {
            callData = abi.encodeWithSignature("oftVersion()");
            result = abi.encode(bytes4(0x02e49c2c), uint64(2));
        } else if (field == 8) {
            target = address(ethEndpoint);
            callData = abi.encodeWithSignature("eid()");
            result = abi.encode(uint32(30184));
        } else {
            callData = abi.encodeWithSignature("decimals()");
            result = abi.encode(uint8(6));
        }
        vm.mockCall(target, callData, result);
        vm.prank(alice);
        token.approve(address(garden), 1e18);
        uint256 balance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        garden.buyCandlesWithWish(1, 2, "must roll back", true);
        vm.expectRevert();
        treasury.quoteDispatch(0.6e18);
        vm.expectRevert();
        treasury.dispatch{value: 0.001 ether}(0.6e18, 1);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.allowance(alice, address(garden)), 1e18);
        assertEq(garden.wishBatch(PREFIX + 3), 0);
        assertEq(treasury.batchCount(), 0);
        _assertAccounting(2);
        vm.clearMockedCalls();
        _buy(1, 2, "retry succeeds");
        _dispatch(0.9e18);
        _assertAccounting(3);
    }

    function testFuzz_badAcknowledgementReceiptRollsBackFeeAndNeverReburns(uint8 faultSeed) public {
        _buy(1, 0, "");
        (uint256 id, bytes32 guid) = _dispatch(0.3e18);
        _burn(id, guid, 0.3e18);
        uint8 fault = faultSeed % 3;
        MessagingReceipt memory receipt = MessagingReceipt(
            fault == 0 ? bytes32(0) : keccak256("receipt"),
            1,
            MessagingFee(fault == 1 ? 0.001 ether + 1 : 0.001 ether, fault == 2 ? 1 : 0)
        );
        vm.mockCall(
            address(baseEndpoint), abi.encodeWithSelector(IBridgeEndpoint.send.selector), abi.encode(receipt)
        );
        uint256 nativeBalance = address(this).balance;
        vm.expectRevert(BaseBurnReceiver.IncorrectNativeFee.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        assertEq(address(this).balance, nativeBalance);
        assertEq(receiver.totalBurned(), 0.3e18);
        assertEq(baseToken.totalSupply(), 0);
        assertEq(treasury.confirmedBurn(), 0);
        vm.clearMockedCalls();
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        _deliverAck(baseEndpoint.lastMessage());
        assertEq(treasury.confirmedBurn(), 0.3e18);
    }

    function test_nonNativeFeeQuoteIsRejectedOnBothChains() public {
        _buy(1, 0, "");
        vm.mockCall(
            IMD,
            abi.encodeWithSignature("quoteSend((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),bool)"),
            abi.encode(MessagingFee(0.001 ether, 1))
        );
        vm.expectRevert(IMDBurnQueue.IncorrectNativeFee.selector);
        treasury.quoteDispatch(0.3e18);
        vm.expectRevert(IMDBurnQueue.IncorrectNativeFee.selector);
        treasury.dispatch{value: 0.001 ether}(0.3e18, 1);
        vm.clearMockedCalls();
        vm.chainId(8453);
        vm.mockCall(
            address(baseEndpoint),
            abi.encodeWithSelector(IBridgeEndpoint.quote.selector),
            abi.encode(MessagingFee(0.001 ether, 1))
        );
        vm.expectRevert(BaseBurnReceiver.IncorrectNativeFee.selector);
        receiver.quoteAcknowledgement(0);
        vm.expectRevert(BaseBurnReceiver.IncorrectNativeFee.selector);
        receiver.sendAcknowledgement{value: 0.001 ether}(0);
        vm.clearMockedCalls();
        vm.chainId(1);
        _assertAccounting(1);
        assertEq(treasury.batchCount(), 0);
    }

    function test_walletGasAcknowledgementsReceiptsAndAllWithdrawalBuckets() public {
        _buy(10, 0, "");
        vm.chainId(8453);
        assertSameAtWalletGas(
            alice, address(receiver), 0.001 ether, abi.encodeCall(receiver.sendAcknowledgement, (0))
        );
        vm.chainId(1);
        (uint256 id, bytes32 guid) = _dispatch(3e18);
        _burn(id, guid, 3e18);
        assertSameAtWalletGas(
            alice, address(receiver), 0.001 ether, abi.encodeCall(receiver.sendAcknowledgement, (id))
        );
        receiver.sendAcknowledgement{value: 0.001 ether}(id);
        bytes memory ack = baseEndpoint.lastMessage();
        vm.chainId(1);
        bytes memory data = abi.encodeCall(treasury.lzReceive, (_origin(), guid, ack, alice, bytes("")));
        assertSameAtWalletGas(address(ethEndpoint), address(treasury), data);
        _deliverAck(ack);
        assertSameAtWalletGas(address(ethEndpoint), address(treasury), data); // idempotent receipt
        assertSameAtWalletGas(
            OWNER, address(treasury), abi.encodeCall(treasury.withdrawEcosystem, (bob, 5e18))
        );
        assertSameAtWalletGas(
            OWNER, address(treasury), abi.encodeCall(treasury.withdrawOperations, (bob, 1e18))
        );
        assertSameAtWalletGas(OWNER, address(treasury), abi.encodeCall(treasury.withdrawFounder, (bob, 1e18)));
        assertEq(treasury.confirmedBurn(), 3e18);
        assertEq(receiver.totalBurned(), 3e18);
    }

    function _origin() private view returns (Origin memory) {
        return Origin(30184, bytes32(uint256(uint160(address(receiver)))), 1);
    }

    function _word(bytes memory data, uint256 offset, uint256 value) private pure {
        require(offset + 32 <= data.length, "test mutation out of bounds");
        assembly ("memory-safe") { mstore(add(add(data, 32), offset), value) }
    }

    /// @notice Independent model of the revised dispatch rule: min(maxAmount, pending, frozen maxBatch) rounded
    ///         down to a shared unit; below one candle's share only when it is the whole pending balance; `maxBatchId` is an
    ///         upper bound. The quote equals what dispatch does, and a refused dispatch changes nothing.
    function testFuzz_dispatchClampMinimumAndBatchBoundMatchModel(
        uint8 candleSeed,
        uint96 firstSeed,
        uint256 requestSeed,
        uint8 boundSeed
    ) public {
        uint256 n = bound(candleSeed, 1, 200); // up to 60 IMD pending: twice the 30 IMD frozen cap
        for (uint256 left = n; left != 0;) {
            uint256 chunk = left > 50 ? 50 : left;
            _buy(chunk, 0, "");
            left -= chunk;
        }
        uint256 first = bound(firstSeed, 0, n * 0.3e18);
        if (first >= 0.3e18) {
            vm.prank(bob);
            treasury.dispatch{value: 0.001 ether}(first, 1);
        }
        uint256 pending = treasury.pendingBurn();
        uint256 inTransit = treasury.inTransitBurn();
        uint256 count = treasury.batchCount();
        assertEq(pending + inTransit, n * 0.3e18);
        uint256 request = bound(requestSeed, 0, n * 0.6e18);
        uint256 capped = request > pending ? pending : request;
        if (capped > MAX_BATCH) capped = MAX_BATCH;
        uint256 amount = capped / 1e12 * 1e12;
        bool valid = amount != 0 && (amount >= 0.3e18 || amount == pending);
        bool stale = boundSeed % 4 == 3;
        uint256 maxBatchId = stale ? count : count + 1 + boundSeed % 3;
        if (valid) {
            (uint256 qAmount, uint256 qDust,, uint256 qNext) = treasury.quoteDispatch(request);
            assertEq(qAmount, amount);
            assertEq(qDust, capped - amount);
            assertEq(qNext, count + 1);
        } else {
            vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
            treasury.quoteDispatch(request);
        }
        if (!valid || stale) {
            vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
            treasury.dispatch{value: 0.001 ether}(request, maxBatchId);
            assertEq(treasury.pendingBurn(), pending);
            assertEq(treasury.inTransitBurn(), inTransit);
            assertEq(treasury.batchCount(), count);
            return;
        }
        vm.expectEmit(true, false, false, false, address(treasury));
        emit IMDBurnQueue.BurnDispatched(count + 1, bytes32(0), amount, capped - amount);
        uint256 id = treasury.dispatch{value: 0.001 ether}(request, maxBatchId);
        assertEq(id, count + 1);
        (bytes32 guid, uint256 recorded, bool confirmed) = treasury.batches(id);
        assertTrue(guid != bytes32(0));
        assertEq(recorded, amount);
        assertFalse(confirmed);
        assertEq(token.lastAmount(), amount);
        assertEq(treasury.pendingBurn(), pending - amount);
        assertEq(treasury.inTransitBurn(), inTransit + amount);
        assertEq(treasury.pendingBurn() % 1e12, 0, "pending never holds unbridgeable dust");
        assertLe(amount, MAX_BATCH);
        _assertAccounting(n);
    }

    /// @notice Finding 89832d9 settled: a third party asking for everything gets at most the frozen maximum
    ///         batch per dispatch, which equals the bound the derived receiver checked; the rest stays pending.
    function test_thirdPartyUnboundedDispatchIsSplitAtFrozenMaximum() public {
        for (uint256 i; i < 4; ++i) {
            _buy(50, 0, ""); // 60 IMD burn share pending
        }
        assertEq(treasury.maxBatch(), MAX_BATCH);
        assertEq(receiver.maxBatch(), treasury.maxBatch(), "Ethereum cap is the receiver's checked bound");
        (uint256 quoted,,,) = treasury.quoteDispatch(type(uint256).max);
        assertEq(quoted, MAX_BATCH);
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        assertEq(treasury.dispatch{value: 0.001 ether}(type(uint256).max, type(uint256).max), 1);
        assertEq(treasury.dispatch{value: 0.001 ether}(type(uint256).max, type(uint256).max), 2);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(type(uint256).max, type(uint256).max);
        vm.stopPrank();
        (, uint256 a1,) = treasury.batches(1);
        (, uint256 a2,) = treasury.batches(2);
        assertEq(a1, MAX_BATCH);
        assertEq(a2, MAX_BATCH);
        assertEq(treasury.pendingBurn(), 0);
        assertEq(treasury.inTransitBurn(), 60e18);
        // The frozen bound cannot be changed afterwards by the owner either.
        vm.prank(OWNER);
        vm.expectRevert(IMDBurnQueue.ConfigurationFrozen.selector);
        treasury.freezeBridge(
            address(ethEndpoint),
            address(baseEndpoint),
            address(adapter),
            GAS,
            GAS,
            GAS,
            1000e18,
            SALT,
            EVIDENCE
        );
        assertEq(treasury.maxBatch(), MAX_BATCH);
    }
}
