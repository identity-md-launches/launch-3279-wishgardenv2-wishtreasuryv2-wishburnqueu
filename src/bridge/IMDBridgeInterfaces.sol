// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ABI-compatible subsets of the verified IMD OFT / LayerZero V2 interfaces.
// Provenance and exact upstream interface snapshots: docs/bridge/ and docs/verification.md.
struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

interface IIMDOFT {
    function token() external view returns (address);
    function approvalRequired() external view returns (bool);
    function endpoint() external view returns (address);
    function peers(uint32 eid) external view returns (bytes32);
    function decimalConversionRate() external view returns (uint256);
    function sharedDecimals() external view returns (uint8);
    function oftVersion() external view returns (bytes4, uint64);
    function quoteSend(SendParam calldata params, bool payInLzToken)
        external
        view
        returns (MessagingFee memory);
    function send(SendParam calldata params, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);
}

interface IBridgeEndpoint {
    function eid() external view returns (uint32);
    function quote(MessagingParams calldata params, address sender)
        external
        view
        returns (MessagingFee memory);
    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory);
}

interface IBurnableIMD {
    function burn(uint256 amount) external;
}

/// @notice Transfer-restriction views of the verified Base IMD runtime (selectors present in its dispatcher).
/// @dev Its `_transfer` enforces blacklist and, while `limitsInEffect`, `maxWallet` for non-excluded
///      recipients and `tradingActive` unless sender or recipient is fee-excluded; ERC20Burnable `burn`
///      bypasses `_transfer`, so a zero-burn probe alone cannot see them.
interface IBaseIMDRestrictions {
    function isBlacklisted(address account) external view returns (bool);
    function limitsInEffect() external view returns (bool);
    function tradingActive() external view returns (bool);
    function isExcludedFromFees(address account) external view returns (bool);
    function maxWallet() external view returns (uint256);
    function _isExcludedMaxTransactionAmount(address account) external view returns (bool);
}
