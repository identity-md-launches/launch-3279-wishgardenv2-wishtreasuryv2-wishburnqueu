// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Exact record layout and read selectors from the pinned legacy ABI.
interface ILegacyWishGarden {
    struct Candle {
        address purchaser;
        uint64 createdAt;
        uint8 style;
        bool freeClaim;
        uint256 position;
        uint256 nftTokenId;
    }
    function getCandle(uint256 candleId) external view returns (Candle memory);
    function getCandles(uint256 firstId, uint256 limit) external view returns (Candle[] memory, uint256);
    function candleCountOf(address purchaser) external view returns (uint256);
    function candleIdsOf(address purchaser, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory, uint256);
    function nftClaimedCandle(uint256 tokenId) external view returns (uint256);
    function totalCandles() external view returns (uint256);
}

interface ILegacyTreasury {
    function burnSink() external view returns (address);
    function totalIMDLocked() external view returns (uint256);
    function totalPayments() external view returns (uint256);
    function ecosystemBalance() external view returns (uint256);
    function operationsBalance() external view returns (uint256);
    function founderBalance() external view returns (uint256);
}
