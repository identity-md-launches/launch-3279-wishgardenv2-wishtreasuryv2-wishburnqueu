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
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, GAS, SALT, EVIDENCE
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
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, GAS, SALT, bytes32(0)
        );
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        t.freezeBridge(
            address(baseEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, GAS, SALT, EVIDENCE
        );
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        t.freezeBridge(address(ethEndpoint), address(baseEndpoint), bob, GAS, GAS, GAS, SALT, EVIDENCE);
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        t.freezeBridge(address(ethEndpoint), address(0), address(adapter), GAS, GAS, GAS, SALT, EVIDENCE);
        vm.expectRevert(IMDBurnQueue.InvalidBridgeConfiguration.selector);
        t.freezeBridge(
            address(ethEndpoint), address(baseEndpoint), address(adapter), GAS, GAS, 99_999, SALT, EVIDENCE
        );
        vm.stopPrank();
        assertFalse(t.bridgeFrozen());
    }

    /// @notice The receiver is derived from the compiled receiver code, the treasury and the fixed EIDs;
    ///         it matches the deterministic deployer's actual CREATE2 result and no owner argument names it.
    function test_receiverIsDerivedFromCompiledCodeTreasuryAndSaltNotOwnerChoice() public {
        assertEq(treasury.receiverCreationCodeHash(), keccak256(type(BaseBurnReceiver).creationCode));
        assertEq(treasury.baseReceiver(), address(receiver));
        assertEq(treasury.receiverSalt(), SALT);
        assertEq(treasury.baseEndpoint(), address(baseEndpoint));
        assertEq(treasury.acknowledgementGas(), GAS);
        assertEq(receiver.ethereumQueue(), address(treasury));
        assertEq(receiver.ethereumEid(), treasury.ETHEREUM_EID());
        assertEq(receiver.baseEid(), treasury.BASE_EID());
        assertGt(address(receiver).code.length, 0);
        // Another treasury, salt, gas or adapter derives a different address.
        WishGardenTreasury other = new WishGardenTreasury(OWNER);
        assertTrue(
            other.predictReceiver(address(baseEndpoint), address(adapter), GAS, SALT) != address(receiver)
        );
        assertTrue(
            treasury.predictReceiver(address(baseEndpoint), address(adapter), GAS, keccak256("other"))
                != address(receiver)
        );
        assertTrue(
            treasury.predictReceiver(address(baseEndpoint), address(adapter), GAS + 1, SALT)
                != address(receiver)
        );
        assertTrue(treasury.predictReceiver(address(baseEndpoint), bob, GAS, SALT) != address(receiver));
        // The same salt places a receiver bound to a different queue at a different address, never at the
        // frozen one, and the frozen address is already occupied by the code bound to this treasury.
        BaseBurnReceiver forOther = _deployReceiver(address(other), SALT);
        assertTrue(address(forOther) != address(receiver));
        assertEq(forOther.ethereumQueue(), address(other));
        (bool ok,) = CREATE2_DEPLOYER.call(
            bytes.concat(
                SALT,
                type(BaseBurnReceiver).creationCode,
                abi.encode(
                    address(baseEndpoint),
                    address(adapter),
                    address(treasury),
                    uint32(30101),
                    uint32(30184),
                    GAS
                )
            )
        );
        assertFalse(ok, "frozen address cannot be redeployed");
        // The predicted address for a fresh salt is empty until the compiled code is deployed there.
        bytes32 fresh = keccak256("fresh");
        address predicted = treasury.predictReceiver(address(baseEndpoint), address(adapter), GAS, fresh);
        assertEq(predicted.code.length, 0);
        BaseBurnReceiver deployed = _deployReceiver(address(treasury), fresh);
        assertEq(address(deployed), predicted);
        // Live-observed deployer facts the derivation relies on.
        assertEq(CREATE2_DEPLOYER.codehash, treasury.CREATE2_DEPLOYER_CODE_HASH());
        assertEq(treasury.ETHEREUM_EID(), 30101);
        assertEq(treasury.BASE_EID(), 30184);
    }

    /// @notice Reproduction of the reopened finding: an owner-named EOA can no longer become the receiver,
    ///         receive the burn allocation or forge READY/BURNED, because no freeze argument names one.
    function test_ownerCannotFreezeAnEOAReceiverAndEOAMessagesNeverAuthenticate() public {
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        WishGarden g = new WishGarden(OWNER, address(t));
        address eoa = 0x0000000000000000000000000000000000000Bad;
        vm.startPrank(OWNER);
        t.bindGarden(address(g));
        t.freezeBridge(
            address(ethEndpoint),
            address(baseEndpoint),
            address(adapter),
            GAS,
            GAS,
            GAS,
            keccak256("x"),
            EVIDENCE
        );
        vm.stopPrank();
        assertTrue(t.baseReceiver() != eoa);
        assertEq(t.baseReceiver().code.length, 0, "not deployed yet: nobody can send from it");
        bytes memory ready =
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(address(adapter)))), uint256(8453));
        vm.prank(address(ethEndpoint));
        vm.expectRevert(IMDBurnQueue.UnauthenticatedMessage.selector);
        t.lzReceive(Origin(30184, bytes32(uint256(uint160(eoa))), 1), keccak256(ready), ready, alice, "");
        assertFalse(t.receiverReady());
        vm.prank(OWNER);
        vm.expectRevert(IMDBurnQueue.BridgeNotReady.selector);
        t.activatePurchases();
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
        assertLe(address(treasury).code.length, 24576, "treasury embeds the receiver creation code");
        assertLe(type(LegacyWishRegistry).creationCode.length, 49152);
        assertLe(type(BaseBurnReceiver).creationCode.length + 192, 49152);
    }
}
