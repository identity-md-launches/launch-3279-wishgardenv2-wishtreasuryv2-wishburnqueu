// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {WishGarden} from "../src/WishGarden.sol";
import {WishGardenTreasury} from "../src/WishGardenTreasury.sol";

/// @notice Separate, reviewable transactions; never auto-activate after binding or freezing.
contract OwnerSetup is Script {
    address public constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;

    function bind(address queue, address garden) external {
        _check(queue);
        require(garden.code.length != 0 && address(WishGarden(garden).treasury()) == queue, "garden mismatch");
        vm.startBroadcast(OWNER);
        WishGardenTreasury(queue).bindGarden(garden);
        vm.stopBroadcast();
    }

    function freeze(
        address queue,
        address endpoint,
        uint32 ethereumEid,
        uint32 baseEid,
        address baseOFT,
        address verifiedBaseReceiver,
        uint128 receiveGas,
        uint128 composeGas,
        bytes32 reviewedEvidence
    ) external {
        _check(queue);
        vm.startBroadcast(OWNER);
        WishGardenTreasury(queue)
            .freezeBridge(
                endpoint,
                ethereumEid,
                baseEid,
                baseOFT,
                verifiedBaseReceiver,
                receiveGas,
                composeGas,
                reviewedEvidence
            );
        vm.stopBroadcast();
    }

    function activate(address queue, bytes32 expectedConfigurationHash) external {
        _check(queue);
        WishGardenTreasury t = WishGardenTreasury(queue);
        require(
            expectedConfigurationHash != bytes32(0) && t.configurationHash() == expectedConfigurationHash,
            "configuration changed/unreviewed"
        );
        require(t.receiverReady() && t.bridgeFrozen() && !t.purchasesEnabled(), "setup incomplete");
        vm.startBroadcast(OWNER);
        t.activatePurchases();
        vm.stopBroadcast();
    }

    function _check(address queue) private view {
        require(block.chainid == 1 && queue.code.length != 0, "Ethereum confirmed queue required");
        require(
            WishGardenTreasury(queue).owner() == OWNER,
            "use the current owner's reviewed workflow after ownership transfer"
        );
    }
}
