// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IBurnableIMD,
    IBaseIMDRestrictions,
    IIMDOFT,
    IBridgeEndpoint,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "../../src/bridge/IMDBridgeInterfaces.sol";
import {BridgeMessages} from "../../src/bridge/BridgeMessages.sol";

/// @notice BASE ONLY. Fixed official OFT credits can ONLY be burned. No owner, approval, transfer or rescue.
/// @dev Deploy separately through the deterministic CREATE2 deployer with the salt frozen on Ethereum, so the
///      address equals the one the Ethereum treasury derived from this exact code. Never put this in the
///      Ethereum manifest.
contract BaseBurnReceiver is ReentrancyGuard {
    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant ETHEREUM_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 public constant CHAIN_ID = 8453;
    /// @notice Lower bound of `maxBatch` (one candle's burn share, the Ethereum queue's minimum batch).
    uint256 public constant MIN_CREDIT = 0.3e18;
    address public immutable endpoint;
    address public immutable baseOFT;
    address public immutable ethereumQueue;
    uint32 public immutable ethereumEid;
    uint32 public immutable baseEid;
    uint128 public immutable acknowledgementGas;
    /// @notice Largest single batch the Ethereum queue may dispatch. Frozen there and part of this address's
    ///         derivation, so readiness is only signalled while one such credit can actually land here.
    uint256 public immutable maxBatch;
    /// @notice IMD burned for authenticated batches.
    uint256 public totalBurned;
    /// @notice IMD this receiver burned outside a batch compose and not attributed to a batch: direct
    ///         transfers ("donations"), plus any batch credit burned by `burnSurplus` before its compose ran,
    ///         which that compose then draws back out. Real burns by this contract equal
    ///         `totalBurned + surplusBurned`, so `totalBurned` never exceeds what was actually destroyed.
    uint256 public surplusBurned;

    struct Burn {
        bytes32 guid;
        uint256 amount;
    }
    mapping(uint256 => Burn) public burns;
    mapping(bytes32 => bool) public consumedGuid;
    error InvalidConfiguration();
    error WrongChain();
    error UnauthenticatedCompose();
    error InvalidCompose();
    error DuplicateBurn();
    error InexactBurn();
    error UnknownBatch();
    error IncorrectNativeFee();
    error CreditRestricted();
    event IMDBurned(
        uint256 indexed batchId,
        bytes32 indexed guid,
        uint256 amount,
        uint256 supplyBefore,
        uint256 supplyAfter
    );
    event AcknowledgementSent(uint256 indexed batchId, bytes32 indexed messageGuid);
    event SurplusBurned(address indexed caller, uint256 amount, uint256 supplyBefore, uint256 supplyAfter);

    constructor(
        address endpoint_,
        address baseOFT_,
        address ethereumQueue_,
        uint32 ethereumEid_,
        uint32 baseEid_,
        uint128 acknowledgementGas_,
        uint256 maxBatch_
    ) {
        if (
            endpoint_ == address(0) || baseOFT_ == address(0) || ethereumQueue_ == address(0)
                || baseOFT_ == IMD || baseOFT_ == address(this) || ethereumEid_ == 0 || baseEid_ == 0
                || ethereumEid_ == baseEid_ || acknowledgementGas_ < 100_000
                || acknowledgementGas_ > 5_000_000 || maxBatch_ < MIN_CREDIT
        ) {
            revert InvalidConfiguration();
        }
        endpoint = endpoint_;
        baseOFT = baseOFT_;
        ethereumQueue = ethereumQueue_;
        ethereumEid = ethereumEid_;
        baseEid = baseEid_;
        acknowledgementGas = acknowledgementGas_;
        maxBatch = maxBatch_;
    }

    /// @notice LayerZero OFTComposeMsgCodec v1: nonce(8), srcEid(4), amountLD(32), composeFrom(32), payload(96).
    function lzCompose(address from, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        _requireBase();
        if (msg.sender != endpoint || from != baseOFT) revert UnauthenticatedCompose();
        if (msg.value != 0 || guid == bytes32(0) || message.length != 172) revert InvalidCompose();
        if (
            uint32(bytes4(message[8:12])) != ethereumEid
                || bytes32(message[44:76]) != BridgeMessages.addressWord(ethereumQueue)
        ) {
            revert UnauthenticatedCompose();
        }
        uint256 creditedAmount = uint256(bytes32(message[12:44]));
        (uint256 version, uint256 batchId, uint256 expectedAmount) =
            abi.decode(message[76:], (uint256, uint256, uint256));
        if (
            version != BridgeMessages.VERSION || batchId == 0 || expectedAmount == 0
                || expectedAmount != creditedAmount
        ) {
            revert InvalidCompose();
        }
        if (consumedGuid[guid] || burns[batchId].amount != 0) revert DuplicateBurn();
        // CEI plus guard. A shortage, false burn, revert or OOG rolls back consumption and permits exact retry.
        consumedGuid[guid] = true;
        burns[batchId] = Burn(guid, creditedAmount);
        totalBurned += creditedAmount;
        // The adapter credits this receiver before it queues the compose. If `burnSurplus` already burned
        // part of that credit, the shortfall is taken from `surplusBurned` (really burned, not yet attributed);
        // nothing else can cover a shortage, so a compose without its credit still reverts.
        uint256 held = IERC20(IMD).balanceOf(address(this));
        uint256 fromBalance = held < creditedAmount ? held : creditedAmount;
        uint256 alreadyBurned = creditedAmount - fromBalance;
        if (alreadyBurned > surplusBurned) revert InexactBurn();
        surplusBurned -= alreadyBurned;
        (uint256 beforeSupply, uint256 afterSupply) = _burnExact(fromBalance);
        emit IMDBurned(batchId, guid, creditedAmount, beforeSupply, afterSupply);
    }

    /// @notice Anyone may burn every IMD this receiver holds. Nothing can leave it any other way.
    /// @dev A direct transfer to the receiver would otherwise sit here forever and use up the Base token's
    ///      max-wallet headroom, blocking readiness and every later adapter credit. Burning it frees the
    ///      headroom and makes the donation a real supply burn. Burning a batch credit before its compose is
    ///      harmless: the amount is remembered in `surplusBurned` and that compose completes from it.
    function burnSurplus() external nonReentrant returns (uint256 amount) {
        _requireBase();
        amount = _burnHeld();
        if (amount == 0) revert InexactBurn();
    }

    /// @notice batchId 0 is a readiness handshake; positive IDs acknowledge already completed burns only.
    function quoteAcknowledgement(uint256 batchId) external view returns (uint256 nativeFee) {
        _requireBase();
        MessagingFee memory fee = IBridgeEndpoint(endpoint).quote(_ackParams(batchId), address(this));
        if (fee.lzTokenFee != 0) revert IncorrectNativeFee();
        return fee.nativeFee;
    }

    /// @notice Permissionless fee-funded maintenance. Failed/repeated acknowledgements never burn again.
    function sendAcknowledgement(uint256 batchId)
        external
        payable
        nonReentrant
        returns (bytes32 messageGuid)
    {
        _requireBase();
        if (batchId == 0) {
            // Burn whatever is held first (also proves the public burn selector is callable, even for zero),
            // so a donation can never keep the credit headroom below one maximum batch.
            _burnHeld();
            _checkDependencies();
        }
        MessagingParams memory params = _ackParams(batchId);
        MessagingFee memory fee = IBridgeEndpoint(endpoint).quote(params, address(this));
        if (fee.lzTokenFee != 0 || msg.value != fee.nativeFee) revert IncorrectNativeFee();
        MessagingReceipt memory receipt = IBridgeEndpoint(endpoint).send{value: msg.value}(params, msg.sender);
        if (
            receipt.guid == bytes32(0) || receipt.fee.nativeFee != fee.nativeFee
                || receipt.fee.lzTokenFee != 0
        ) {
            revert IncorrectNativeFee();
        }
        emit AcknowledgementSent(batchId, receipt.guid);
        return receipt.guid;
    }

    function _ackParams(uint256 batchId) private view returns (MessagingParams memory) {
        bytes memory message;
        if (batchId == 0) {
            message =
                abi.encode(BridgeMessages.READY, uint256(0), BridgeMessages.addressWord(baseOFT), CHAIN_ID);
        } else {
            Burn memory burned = burns[batchId];
            if (burned.amount == 0) revert UnknownBatch();
            message = abi.encode(BridgeMessages.BURNED, batchId, burned.guid, burned.amount);
        }
        return MessagingParams(
            ethereumEid,
            BridgeMessages.addressWord(ethereumQueue),
            message,
            BridgeMessages.receiveOptions(acknowledgementGas),
            false
        );
    }

    /// @notice Largest single adapter credit the Base token's transfer limits allow this receiver right now.
    /// @dev Unlimited while limits are off. While they are on: zero if trading is not active and neither the
    ///      adapter nor this receiver is fee-excluded (the token then rejects the transfer); unlimited if the
    ///      receiver is max-transaction excluded; otherwise maxWallet headroom, which `burnSurplus` restores
    ///      to the whole maxWallet. Credits above it revert in the adapter's lzReceive and stay retryable.
    function maxCredit() public view returns (uint256) {
        IBaseIMDRestrictions token = IBaseIMDRestrictions(IMD);
        if (!token.limitsInEffect()) return type(uint256).max;
        if (
            !token.tradingActive() && !token.isExcludedFromFees(baseOFT)
                && !token.isExcludedFromFees(address(this))
        ) return 0;
        if (token._isExcludedMaxTransactionAmount(address(this))) return type(uint256).max;
        uint256 wallet = token.maxWallet();
        uint256 held = IERC20(IMD).balanceOf(address(this));
        return wallet > held ? wallet - held : 0;
    }

    function _checkDependencies() private view {
        IIMDOFT adapter = IIMDOFT(baseOFT);
        (bytes4 interfaceId, uint64 version) = adapter.oftVersion();
        if (
            endpoint.code.length == 0 || IMD.code.length == 0 || IBridgeEndpoint(endpoint).eid() != baseEid
                || adapter.endpoint() != endpoint || adapter.token() != IMD || !adapter.approvalRequired()
                || adapter.peers(ethereumEid) != BridgeMessages.addressWord(ETHEREUM_IMD)
                || adapter.decimalConversionRate() != 1e12 || adapter.sharedDecimals() != 6
                || IERC20Metadata(IMD).decimals() != 18 || interfaceId != 0x02e49c2c || version != 1
        ) {
            revert InvalidConfiguration();
        }
        // A blacklisted receiver or adapter, inactive trading, or a max-wallet below one maximum batch makes
        // credits revert even though burn(0) succeeds. Readiness must not be signalled then.
        IBaseIMDRestrictions token = IBaseIMDRestrictions(IMD);
        if (token.isBlacklisted(address(this)) || token.isBlacklisted(baseOFT) || maxCredit() < maxBatch) {
            revert CreditRestricted();
        }
    }

    function _burnHeld() private returns (uint256 amount) {
        amount = IERC20(IMD).balanceOf(address(this));
        surplusBurned += amount;
        (uint256 beforeSupply, uint256 afterSupply) = _burnExact(amount);
        if (amount != 0) emit SurplusBurned(msg.sender, amount, beforeSupply, afterSupply);
    }

    function _burnExact(uint256 amount) private returns (uint256 beforeSupply, uint256 afterSupply) {
        IERC20 token = IERC20(IMD);
        uint256 beforeBalance = token.balanceOf(address(this));
        beforeSupply = token.totalSupply();
        if (beforeBalance < amount || beforeSupply < amount) revert InexactBurn();
        IBurnableIMD(IMD).burn(amount);
        afterSupply = token.totalSupply();
        if (token.balanceOf(address(this)) != beforeBalance - amount || afterSupply != beforeSupply - amount)
        {
            revert InexactBurn();
        }
    }

    function _requireBase() private view {
        if (block.chainid != CHAIN_ID) revert WrongChain();
    }
}
