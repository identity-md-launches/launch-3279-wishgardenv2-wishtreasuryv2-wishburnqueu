// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMDRuntime} from "../fixtures/IMDRuntime.sol";
import {BaseIMDRuntime} from "../fixtures/BaseIMDRuntime.sol";
import {BaseAdapterRuntime} from "../fixtures/BaseAdapterRuntime.sol";
import {MockEndpoint} from "./Mocks.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {IIMDOFT, Origin} from "../../src/bridge/IMDBridgeInterfaces.sol";

interface IPeerSetup {
    function setPeer(uint32, bytes32) external;
}

/// @notice Real verified token/adapter RUNTIMES with local storage and mocked endpoint transport, not a fork.
contract VerifiedRuntimeTest is Test {
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant BASE_ADAPTER = 0xab152db8aaC047b6757fFCF495FfE88d7712690A;
    address constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;

    function test_actualOFTSendUsesCallerBalanceNoApprovalAndExactCodec() public {
        vm.chainId(1);
        vm.deal(address(this), 1 ether);
        vm.etch(IMD, IMDRuntime.code());
        address endpoint = IIMDOFT(IMD).endpoint();
        vm.etch(endpoint, address(new MockEndpoint(30101)).code);
        vm.store(endpoint, bytes32(0), bytes32(uint256(30101)));
        MockEndpoint(endpoint).setFee(0.001 ether);
        vm.store(IMD, bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.prank(OWNER);
        IPeerSetup(IMD).setPeer(30184, bytes32(uint256(uint160(BASE_ADAPTER))));
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        WishGarden g = new WishGarden(OWNER, address(t));
        address receiver = makeAddr("only local receiver fixture");
        vm.startPrank(OWNER);
        t.bindGarden(address(g));
        t.freezeBridge(
            endpoint, 30101, 30184, BASE_ADAPTER, receiver, 300_000, 300_000, keccak256("fixture evidence")
        );
        vm.stopPrank();
        vm.prank(endpoint);
        t.lzReceive(
            Origin(30184, bytes32(uint256(uint160(receiver))), 1),
            keccak256("ready"),
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(BASE_ADAPTER))), uint256(8453)),
            address(this),
            ""
        );
        vm.prank(OWNER);
        t.activatePurchases();
        deal(IMD, address(this), 10e18, true);
        IERC20(IMD).approve(address(g), 10e18);
        g.buyCandles(10, 0);
        uint256 supply = IERC20(IMD).totalSupply();
        t.dispatch{value: 0.001 ether}(3e18, 1);
        assertEq(IERC20(IMD).balanceOf(address(t)), 7e18);
        assertEq(IERC20(IMD).totalSupply(), supply - 3e18);
        assertEq(IERC20(IMD).allowance(address(t), IMD), 0);
        // Actual OFTMsgCodec message: destination (32), amountSD (8), composeFrom (32), application payload (96).
        assertEq(MockEndpoint(endpoint).lastReceiver(), bytes32(uint256(uint160(BASE_ADAPTER))));
        assertEq(
            MockEndpoint(endpoint).lastMessage(),
            abi.encodePacked(
                bytes32(uint256(uint160(receiver))),
                uint64(3e6),
                bytes32(uint256(uint160(address(t)))),
                abi.encode(uint256(1), uint256(1), uint256(3e18))
            )
        );
        assertEq(t.confirmedBurn(), 0, "source-chain bridge debit is not a confirmed final burn");
    }

    function test_actualBaseBurnDecreasesCallerAndSupplyOnly() public {
        vm.chainId(8453);
        vm.etch(BASE_IMD, BaseIMDRuntime.code());
        vm.etch(BASE_ADAPTER, BaseAdapterRuntime.code());
        assertEq(BASE_IMD.codehash, 0x15021fda4613ae853a7e3199f62df75e6f547ca11d32df53c0b1616f4a80ef4f);
        assertEq(BASE_ADAPTER.codehash, 0x1ad0c62178c048836ae25bc3c56a69579ae1ac8498209281c36acd344063e4da);
        assertEq(IIMDOFT(BASE_ADAPTER).token(), BASE_IMD);
        assertTrue(IIMDOFT(BASE_ADAPTER).approvalRequired());
        assertEq(IIMDOFT(BASE_ADAPTER).decimalConversionRate(), 1e12);
        address endpoint = IIMDOFT(BASE_ADAPTER).endpoint();
        address queue = makeAddr("local queue fixture");
        BaseBurnReceiver receiver = new BaseBurnReceiver(endpoint, BASE_ADAPTER, queue, 30101, 30184, 300_000);
        deal(BASE_IMD, address(receiver), 3e18, true);
        uint256 supply = IERC20(BASE_IMD).totalSupply();
        vm.prank(endpoint);
        receiver.lzCompose(
            BASE_ADAPTER,
            keccak256("guid"),
            abi.encodePacked(
                uint64(1),
                uint32(30101),
                uint256(3e18),
                bytes32(uint256(uint160(queue))),
                abi.encode(uint256(1), uint256(1), uint256(3e18))
            ),
            address(this),
            ""
        );
        assertEq(IERC20(BASE_IMD).totalSupply(), supply - 3e18);
        assertEq(IERC20(BASE_IMD).balanceOf(address(receiver)), 0);
        assertEq(receiver.totalBurned(), 3e18);
    }
}
