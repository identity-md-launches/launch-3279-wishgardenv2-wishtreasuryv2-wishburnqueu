// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Application protocol on top of LayerZero V2 / OFT v1. Not an alternative bridge.
library BridgeMessages {
    uint8 internal constant READY = 1;
    uint8 internal constant BURNED = 2;
    uint256 internal constant VERSION = 1;

    function addressWord(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev LayerZero type-3 executor receive option: worker 1, length 17, type 1, gas uint128.
    function receiveOptions(uint128 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), gasLimit);
    }

    /// @dev Additionally request compose index 0, worker 1, length 19, type 3, index uint16, gas uint128.
    function composeOptions(uint128 receiveGas, uint128 composeGas) internal pure returns (bytes memory) {
        return bytes.concat(
            receiveOptions(receiveGas),
            abi.encodePacked(uint8(1), uint16(19), uint8(3), uint16(0), composeGas)
        );
    }
}
