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
        // Split a whole pending unit at an arbitrary boundary: unrepresentable remainder stays pending.
        _dispatch(0.3e18 - 1);
        assertEq(treasury.pendingBurn(), 1e12);
        _dispatch(1e12);
        assertEq(treasury.pendingBurn(), 0);
        _assertAccounting(2);
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
        treasury.dispatch{value: 0.001 ether}(0.3e18, 2);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(1, 1);
        vm.expectRevert(IMDBurnQueue.InvalidBatch.selector);
        treasury.dispatch{value: 0.001 ether}(1e18, 1);
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
