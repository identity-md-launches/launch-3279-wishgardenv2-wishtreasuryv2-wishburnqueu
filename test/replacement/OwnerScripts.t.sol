// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReplacementTestBase} from "./ReplacementTestBase.sol";
import {DeployBaseReceiver} from "../../script/DeployBaseReceiver.s.sol";
import {OwnerSetup} from "../../script/OwnerSetup.s.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";
import {WishGardenTreasury} from "../../src/WishGardenTreasury.sol";
import {WishGarden} from "../../src/WishGarden.sol";
import {Origin} from "../../src/bridge/IMDBridgeInterfaces.sol";

contract OwnerScriptsTest is ReplacementTestBase {
    function test_ownerBaseScriptDeploysOnlyCorrectChainDependenciesAndDerivedAddress() public {
        DeployBaseReceiver script = new DeployBaseReceiver();
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        bytes32 salt = keccak256("owner script salt");
        address predicted = t.predictReceiver(address(baseEndpoint), address(adapter), GAS, salt);
        assertEq(script.predict(address(baseEndpoint), address(adapter), address(t), GAS, salt), predicted);
        vm.expectRevert("Base required");
        script.run(address(baseEndpoint), address(adapter), address(t), GAS, salt, predicted, EVIDENCE);
        vm.chainId(8453);
        vm.expectRevert("predicted address differs from the Ethereum treasury's");
        script.run(address(baseEndpoint), address(adapter), address(t), GAS, salt, bob, EVIDENCE);
        vm.expectRevert("predicted address differs from the Ethereum treasury's");
        script.run(address(baseEndpoint), address(adapter), address(treasury), GAS, salt, predicted, EVIDENCE);
        BaseBurnReceiver deployed =
            script.run(address(baseEndpoint), address(adapter), address(t), GAS, salt, predicted, EVIDENCE);
        assertEq(address(deployed), predicted);
        assertEq(deployed.ethereumQueue(), address(t));
        assertEq(deployed.baseOFT(), address(adapter));
        vm.expectRevert("already deployed");
        script.run(address(baseEndpoint), address(adapter), address(t), GAS, salt, predicted, EVIDENCE);
        vm.expectRevert("reviewed evidence and confirmed queue required");
        script.run(address(baseEndpoint), address(adapter), address(t), GAS, salt, predicted, bytes32(0));
        vm.expectRevert("wrong endpoint");
        script.run(address(ethEndpoint), address(adapter), address(t), GAS, salt, predicted, EVIDENCE);
        vm.etch(CREATE2_DEPLOYER, hex"00");
        vm.expectRevert("deterministic deployer missing");
        script.run(
            address(baseEndpoint), address(adapter), address(t), GAS, keccak256("2"), predicted, EVIDENCE
        );
    }

    function test_ownerSetupScriptSeparatesFreezeAndActivationWithReviewedHash() public {
        OwnerSetup script = new OwnerSetup();
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        WishGarden g = new WishGarden(OWNER, address(t));
        script.bind(address(t), address(g));
        address derived = script.freeze(
            address(t),
            address(ethEndpoint),
            address(baseEndpoint),
            address(adapter),
            GAS,
            GAS,
            GAS,
            SALT,
            EVIDENCE
        );
        assertEq(derived, t.baseReceiver());
        assertEq(derived, t.predictReceiver(address(baseEndpoint), address(adapter), GAS, SALT));
        assertFalse(t.purchasesEnabled());
        bytes32 config = t.configurationHash();
        vm.expectRevert("setup incomplete");
        script.activate(address(t), config);
        // Only the derived receiver (deployed with the frozen salt for THIS treasury) can signal readiness.
        BaseBurnReceiver deployed = _deployReceiver(address(t), SALT);
        assertEq(address(deployed), derived);
        vm.chainId(8453);
        deployed.sendAcknowledgement{value: 0.001 ether}(0);
        bytes memory ready = baseEndpoint.lastMessage();
        vm.chainId(1);
        vm.prank(address(ethEndpoint));
        t.lzReceive(Origin(30184, bytes32(uint256(uint160(derived))), 1), keccak256("test"), ready, alice, "");
        vm.expectRevert("configuration changed/unreviewed");
        script.activate(address(t), EVIDENCE);
        script.activate(address(t), config);
        assertTrue(t.purchasesEnabled());
    }
}
