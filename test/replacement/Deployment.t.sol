// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReplacementTestBase} from "./ReplacementTestBase.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {LegacyWishRegistry} from "../../src/LegacyWishRegistry.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {IMDBurnQueue} from "../../src/bridge/IMDBurnQueue.sol";
import {Origin} from "../../src/bridge/IMDBridgeInterfaces.sol";

contract ReplacementFactory {
    function deploy(address owner)
        external
        returns (WishGardenTreasury t, WishGarden g, LegacyWishRegistry r)
    {
        t = new WishGardenTreasury(owner);
        g = new WishGarden(owner, address(t));
        r = new LegacyWishRegistry();
    }
}

contract ReplacementDeploymentTest is ReplacementTestBase {
    function test_factoryConstructorsEmptyChainExplicitOwnerDisabledNoInitialization() public {
        vm.etch(IMD, "");
        vm.etch(BASE_IMD, "");
        ReplacementFactory f = new ReplacementFactory();
        (WishGardenTreasury t, WishGarden g, LegacyWishRegistry r) = f.deploy(OWNER);
        assertEq(t.owner(), OWNER);
        assertEq(g.owner(), OWNER);
        assertEq(address(g.treasury()), address(t));
        assertFalse(t.purchasesEnabled());
        assertFalse(t.bridgeFrozen());
        assertFalse(t.receiverReady());
        assertEq(t.garden(), address(0));
        assertEq(t.baseReceiver(), address(0));
        assertEq(r.LEGACY_GARDEN(), registry.LEGACY_GARDEN());
        new BaseBurnReceiver(address(ethEndpoint), address(adapter), address(t), 30101, 30184, 300_000);
    }

    function test_purchasesCannotActivateWithoutFreezeAndAuthenticatedReceiverReadiness() public {
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        WishGarden g = new WishGarden(OWNER, address(t));
        vm.startPrank(OWNER);
        t.bindGarden(address(g));
        vm.expectRevert(IMDBurnQueue.BridgeNotReady.selector);
        t.activatePurchases();
        t.freezeBridge(
            address(ethEndpoint),
            30101,
            30184,
            address(adapter),
            address(receiver),
            300_000,
            300_000,
            EVIDENCE
        );
        vm.expectRevert(IMDBurnQueue.BridgeNotReady.selector);
        t.activatePurchases();
        vm.stopPrank();
        vm.startPrank(alice);
        token.approve(address(g), 1e18);
        vm.expectRevert(WishGarden.PurchasesDisabled.selector);
        g.buyCandles(1, 0);
        vm.stopPrank();
        assertEq(g.totalCandles(), 0);
        assertEq(t.totalPayments(), 0);
    }

    function test_configurationValidatesLocalOfficialInterfacePeerEndpointAndEvidence() public {
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        vm.startPrank(OWNER);
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        t.freezeBridge(
            address(ethEndpoint),
            30101,
            30184,
            address(adapter),
            address(receiver),
            300_000,
            300_000,
            bytes32(0)
        );
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        t.freezeBridge(
            address(baseEndpoint),
            30101,
            30184,
            address(adapter),
            address(receiver),
            300_000,
            300_000,
            EVIDENCE
        );
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        t.freezeBridge(address(ethEndpoint), 30101, 30184, bob, address(receiver), 300_000, 300_000, EVIDENCE);
        vm.stopPrank();
        assertFalse(t.bridgeFrozen());
    }

    function test_allReplacementRuntimeAndInitcodeSizesAndNoForbiddenOpcodes() public view {
        address[4] memory apps = [address(garden), address(treasury), address(registry), address(receiver)];
        for (uint256 i; i < apps.length; ++i) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24576);
            bool reachable = true;
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op == 0x5b) reachable = true;
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
                if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                    reachable = false;
                }
            }
        }
        assertLe(type(WishGarden).creationCode.length + 64, 49152);
        assertLe(type(WishGardenTreasury).creationCode.length + 32, 49152);
        assertLe(type(LegacyWishRegistry).creationCode.length, 49152);
        assertLe(type(BaseBurnReceiver).creationCode.length + 192, 49152);
    }
}
