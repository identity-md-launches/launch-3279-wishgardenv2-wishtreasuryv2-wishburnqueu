// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {BaseBurnReceiver} from "../base/src/BaseBurnReceiver.sol";
import {IIMDOFT, IBridgeEndpoint} from "../src/bridge/IMDBridgeInterfaces.sol";

/// @notice Run by the named OWNER with their own wallet after Ethereum deployment and route verification.
/// @dev Deploys through the deterministic CREATE2 deployer (same address/code on Ethereum and Base) with the salt
///      the Ethereum treasury froze, so the receiver lands exactly at the address the treasury derived from this
///      compiled code. No private keys or environment values are read here. Forge simulation is the default;
///      broadcasting is an explicit owner action.
contract DeployBaseReceiver is Script {
    address public constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    address public constant BASE_IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant ETHEREUM_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant CREATE2_DEPLOYER_CODE_HASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    uint32 public constant ETHEREUM_EID = 30101;
    uint32 public constant BASE_EID = 30184;

    /// @notice Address this script will deploy to for the given arguments; compare with the Ethereum treasury's
    ///         `baseReceiver()` (after freeze) or `predictReceiver(...)` (before freeze).
    function predict(
        address endpoint,
        address baseOFT,
        address confirmedEthereumQueue,
        uint128 acknowledgementGas,
        uint256 maxBatch,
        bytes32 salt
    ) public pure returns (address) {
        bytes32 initCodeHash = keccak256(
            _initCode(endpoint, baseOFT, confirmedEthereumQueue, acknowledgementGas, maxBatch)
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash))))
        );
    }

    function run(
        address endpoint,
        address baseOFT,
        address confirmedEthereumQueue,
        uint128 acknowledgementGas,
        uint256 maxBatch,
        bytes32 salt,
        address expectedReceiver,
        bytes32 reviewedEvidence
    ) external returns (BaseBurnReceiver receiver) {
        require(block.chainid == 8453, "Base required");
        require(
            reviewedEvidence != bytes32(0) && confirmedEthereumQueue != address(0),
            "reviewed evidence and confirmed queue required"
        );
        require(endpoint.code.length != 0 && baseOFT.code.length != 0, "missing dependency");
        require(CREATE2_DEPLOYER.codehash == CREATE2_DEPLOYER_CODE_HASH, "deterministic deployer missing");
        require(IBridgeEndpoint(endpoint).eid() == BASE_EID, "wrong endpoint");
        require(
            IIMDOFT(baseOFT).endpoint() == endpoint && IIMDOFT(baseOFT).token() == BASE_IMD, "wrong adapter"
        );
        require(
            IIMDOFT(baseOFT).peers(ETHEREUM_EID) == bytes32(uint256(uint160(ETHEREUM_IMD))),
            "wrong reciprocal peer"
        );
        address predicted =
            predict(endpoint, baseOFT, confirmedEthereumQueue, acknowledgementGas, maxBatch, salt);
        require(predicted == expectedReceiver, "predicted address differs from the Ethereum treasury's");
        require(predicted.code.length == 0, "already deployed");
        vm.startBroadcast(OWNER);
        (bool ok, bytes memory returned) = CREATE2_DEPLOYER.call(
            bytes.concat(
                salt, _initCode(endpoint, baseOFT, confirmedEthereumQueue, acknowledgementGas, maxBatch)
            )
        );
        vm.stopBroadcast();
        require(ok && returned.length == 20, "deterministic deployment failed");
        receiver = BaseBurnReceiver(address(bytes20(returned)));
        require(address(receiver) == predicted && predicted.code.length != 0, "unexpected receiver address");
        require(
            receiver.ethereumQueue() == confirmedEthereumQueue && receiver.baseOFT() == baseOFT
                && receiver.endpoint() == endpoint && receiver.maxBatch() == maxBatch,
            "receiver bindings differ"
        );
    }

    function _initCode(
        address endpoint,
        address baseOFT,
        address queue,
        uint128 acknowledgementGas,
        uint256 maxBatch
    ) private pure returns (bytes memory) {
        return bytes.concat(
            type(BaseBurnReceiver).creationCode,
            abi.encode(endpoint, baseOFT, queue, ETHEREUM_EID, BASE_EID, acknowledgementGas, maxBatch)
        );
    }
}
