// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {BaseBurnReceiver} from "../base/src/BaseBurnReceiver.sol";
import {IIMDOFT, IBridgeEndpoint} from "../src/bridge/IMDBridgeInterfaces.sol";

/// @notice Run by the named OWNER with their own wallet after Ethereum deployment and route verification.
/// @dev No private keys or environment values are read here. Forge simulation is the default; broadcasting is an explicit owner action.
contract DeployBaseReceiver is Script {
    address public constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    address public constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant ETHEREUM_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function run(
        address endpoint,
        address baseOFT,
        address confirmedEthereumQueue,
        uint32 ethereumEid,
        uint32 baseEid,
        uint128 acknowledgementGas,
        bytes32 reviewedEvidence
    ) external returns (BaseBurnReceiver receiver) {
        require(block.chainid == 8453, "Base required");
        require(
            reviewedEvidence != bytes32(0) && confirmedEthereumQueue != address(0),
            "reviewed evidence and confirmed queue required"
        );
        require(endpoint.code.length != 0 && baseOFT.code.length != 0, "missing dependency");
        require(IBridgeEndpoint(endpoint).eid() == baseEid, "wrong endpoint");
        require(
            IIMDOFT(baseOFT).endpoint() == endpoint && IIMDOFT(baseOFT).token() == BASE_IMD, "wrong adapter"
        );
        require(
            IIMDOFT(baseOFT).peers(ethereumEid) == bytes32(uint256(uint160(ETHEREUM_IMD))),
            "wrong reciprocal peer"
        );
        vm.startBroadcast(OWNER);
        receiver = new BaseBurnReceiver(
            endpoint, baseOFT, confirmedEthereumQueue, ethereumEid, baseEid, acknowledgementGas
        );
        vm.stopBroadcast();
    }
}
