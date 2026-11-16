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
    function test_ownerBaseScriptDeploysOnlyCorrectChainAndDependencies() public {
        DeployBaseReceiver script = new DeployBaseReceiver();
        vm.expectRevert("Base required");
        script.run(
            address(baseEndpoint), address(adapter), address(treasury), 30101, 30184, 300_000, EVIDENCE
        );
        vm.chainId(8453);
        BaseBurnReceiver deployed = script.run(
            address(baseEndpoint), address(adapter), address(treasury), 30101, 30184, 300_000, EVIDENCE
        );
        assertEq(deployed.ethereumQueue(), address(treasury));
        assertEq(deployed.baseOFT(), address(adapter));
        vm.expectRevert("reviewed evidence and confirmed queue required");
        script.run(
            address(baseEndpoint), address(adapter), address(treasury), 30101, 30184, 300_000, bytes32(0)
        );
        vm.expectRevert("wrong endpoint");
        script.run(
            address(baseEndpoint), address(adapter), address(treasury), 30101, 30101, 300_000, EVIDENCE
        );
    }

    function test_ownerSetupScriptSeparatesFreezeAndActivationWithReviewedHash() public {
        OwnerSetup script = new OwnerSetup();
        WishGardenTreasury t = new WishGardenTreasury(OWNER);
        WishGarden g = new WishGarden(OWNER, address(t));
        script.bind(address(t), address(g));
        script.freeze(
            address(t),
            address(ethEndpoint),
            30101,
            30184,
            address(adapter),
            address(receiver),
            300_000,
            300_000,
            EVIDENCE
        );
        assertFalse(t.purchasesEnabled());
        bytes32 config = t.configurationHash();
        vm.expectRevert("setup incomplete");
        script.activate(address(t), config);
        vm.prank(address(ethEndpoint));
        t.lzReceive(
            Origin(30184, bytes32(uint256(uint160(address(receiver)))), 1),
            keccak256("test"),
            abi.encode(uint8(1), uint256(0), bytes32(uint256(uint160(address(adapter)))), uint256(8453)),
            alice,
            ""
        );
        vm.expectRevert("configuration changed/unreviewed");
        script.activate(address(t), EVIDENCE);
        script.activate(address(t), config);
        assertTrue(t.purchasesEnabled());
    }
}
