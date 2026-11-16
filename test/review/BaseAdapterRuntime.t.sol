// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WalletGas} from "../helpers/WalletGas.sol";
import {BaseIMDRuntime} from "../fixtures/BaseIMDRuntime.sol";
import {BaseAdapterRuntime} from "../fixtures/BaseAdapterRuntime.sol";
import {MockEndpoint} from "../replacement/Mocks.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {WishGardenTreasury} from "src/WishGardenTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIMDOFT, Origin} from "src/bridge/IMDBridgeInterfaces.sol";

interface IReviewOFTReceiver {
    function setPeer(uint32 eid, bytes32 peer) external;
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

/// @dev Transport is a mock. The token/adapter themselves execute the supplied deployed bytecode.
contract ReviewComposeEndpoint is MockEndpoint {
    address public composeTarget;
    bytes32 public composeGuid;
    uint16 public composeIndex;
    bytes public composeMessage;
    address public composeFrom;

    constructor() MockEndpoint(30184) {}

    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external {
        composeFrom = msg.sender;
        composeTarget = to;
        composeGuid = guid;
        composeIndex = index;
        composeMessage = message;
    }
}

/// @notice Offline runtime compatibility, NOT a fork, real bridge transfer, or verification of live fee/DVN settings.
contract BaseAdapterRuntimeReviewTest is Test, WalletGas {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant BASE_ADAPTER = 0xab152db8aaC047b6757fFCF495FfE88d7712690A;
    address constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    bytes32 constant GUID = keccak256("offline actual adapter packet");
    ReviewComposeEndpoint internal endpoint;
    BaseBurnReceiver internal receiver;
    WishGardenTreasury internal queue;
    IERC20 internal token;

    function setUp() public {
        vm.chainId(8453);
        vm.deal(address(this), 1 ether);
        vm.etch(BASE_IMD, BaseIMDRuntime.code());
        vm.etch(BASE_ADAPTER, BaseAdapterRuntime.code());
        token = IERC20(BASE_IMD);
        address endpointAddress = IIMDOFT(BASE_ADAPTER).endpoint();
        vm.etch(endpointAddress, address(new ReviewComposeEndpoint()).code);
        vm.store(endpointAddress, bytes32(0), bytes32(uint256(30184)));
        endpoint = ReviewComposeEndpoint(endpointAddress);
        endpoint.setFee(0.001 ether);
        // Fresh local storage only. Slot zero is Ownable's owner in this supplied runtime.
        vm.store(BASE_ADAPTER, bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.prank(OWNER);
        IReviewOFTReceiver(BASE_ADAPTER).setPeer(30101, bytes32(uint256(uint160(IMD))));
        queue = new WishGardenTreasury(OWNER);
        receiver = new BaseBurnReceiver(endpointAddress, BASE_ADAPTER, address(queue), 30101, 30184, 300_000);
        assertEq(BASE_IMD.codehash, 0x15021fda4613ae853a7e3199f62df75e6f547ca11d32df53c0b1616f4a80ef4f);
        assertEq(BASE_ADAPTER.codehash, 0x1ad0c62178c048836ae25bc3c56a69579ae1ac8498209281c36acd344063e4da);
    }

    function test_actualAdapterCreditQueuesExactComposeThenBurnsAtWalletGas() public {
        deal(BASE_IMD, BASE_ADAPTER, 3e18, true);
        deal(BASE_IMD, OWNER, 5e18, true);
        uint256 supplyBefore = token.totalSupply();
        _deliverToAdapter(1, 3e18);
        assertEq(token.balanceOf(BASE_ADAPTER), 0);
        assertEq(token.balanceOf(address(receiver)), 3e18);
        assertEq(token.totalSupply(), supplyBefore, "adapter unlock must not pretend to be the final burn");
        assertEq(receiver.totalBurned(), 0);
        assertEq(endpoint.composeFrom(), BASE_ADAPTER);
        assertEq(endpoint.composeTarget(), address(receiver));
        assertEq(endpoint.composeGuid(), GUID);
        assertEq(endpoint.composeIndex(), 0);
        bytes memory message = endpoint.composeMessage();
        assertEq(
            message,
            abi.encodePacked(
                uint64(7),
                uint32(30101),
                uint256(3e18),
                bytes32(uint256(uint160(address(queue)))),
                abi.encode(uint256(1), uint256(1), uint256(3e18))
            )
        );
        assertSameAtWalletGas(
            address(endpoint),
            address(receiver),
            abi.encodeCall(receiver.lzCompose, (BASE_ADAPTER, GUID, message, address(this), bytes("")))
        );
        vm.prank(address(endpoint));
        receiver.lzCompose(BASE_ADAPTER, GUID, message, address(this), "");
        assertEq(token.totalSupply(), supplyBefore - 3e18);
        assertEq(token.balanceOf(OWNER), 5e18);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalBurned(), 3e18);
        receiver.sendAcknowledgement{value: 0.001 ether}(1);
        assertEq(endpoint.lastMessage(), abi.encode(uint8(2), uint256(1), GUID, uint256(3e18)));
        assertEq(endpoint.lastReceiver(), bytes32(uint256(uint160(address(queue)))));
        assertEq(token.allowance(address(receiver), BASE_ADAPTER), 0);
    }

    function test_actualAdapterInsufficientReservesLeavesCreditUnconsumedAndAllowsRetry() public {
        deal(BASE_IMD, BASE_ADAPTER, 3e18 - 1, true);
        uint256 beforeSupply = token.totalSupply();
        vm.expectRevert();
        _deliverToAdapter(1, 3e18);
        assertEq(token.totalSupply(), beforeSupply);
        assertEq(token.balanceOf(BASE_ADAPTER), 3e18 - 1);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(endpoint.composeMessage().length, 0);
        assertFalse(receiver.consumedGuid(GUID));
        deal(BASE_IMD, BASE_ADAPTER, 3e18, true);
        _deliverToAdapter(1, 3e18);
        bytes memory message = endpoint.composeMessage();
        vm.prank(address(endpoint));
        receiver.lzCompose(BASE_ADAPTER, GUID, message, address(this), "");
        assertEq(receiver.totalBurned(), 3e18);
        assertEq(token.totalSupply(), 0);
    }

    function _deliverToAdapter(uint256 batchId, uint256 amount) private {
        require(amount % 1e12 == 0, "fixture requires exact shared units");
        bytes memory packet = abi.encodePacked(
            bytes32(uint256(uint160(address(receiver)))),
            uint64(amount / 1e12),
            bytes32(uint256(uint160(address(queue)))),
            abi.encode(uint256(1), batchId, amount)
        );
        vm.prank(address(endpoint));
        IReviewOFTReceiver(BASE_ADAPTER)
            .lzReceive(Origin(30101, bytes32(uint256(uint160(IMD))), 7), GUID, packet, address(this), "");
    }
}
