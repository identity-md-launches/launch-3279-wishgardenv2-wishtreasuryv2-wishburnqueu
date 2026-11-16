// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GardenEconomy} from "../GardenEconomy.sol";
import {
    IIMDOFT,
    IBridgeEndpoint,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    Origin
} from "./IMDBridgeInterfaces.sol";
import {BridgeMessages} from "./BridgeMessages.sol";
import {BaseBurnReceiver} from "../../base/src/BaseBurnReceiver.sol";

/// @notice Restricted direct IMD OFT sender and authenticated Base burn receipt ledger.
/// @dev No approval, withdrawal, delegate, arbitrary-call or owner confirmation path exists.
///      The Base receiver is never a free owner choice: it is the CREATE2 address that exactly the compiled
///      BaseBurnReceiver creation code, bound to this treasury, gets from the deterministic deployer that
///      exists at the same address on Ethereum and Base. Only that code can ever occupy the frozen address.
abstract contract IMDBurnQueue is GardenEconomy, Ownable2Step, ReentrancyGuard {
    uint256 public constant BRIDGE_UNIT = 1e12; // verified 18 local / 6 shared decimals
    uint32 public constant ETHEREUM_EID = 30101; // LayerZero V2 Ethereum endpoint id (verified eid())
    uint32 public constant BASE_EID = 30184; // LayerZero V2 Base endpoint id (verified eid())
    /// @notice Arachnid deterministic deployment proxy, identical code and address on Ethereum and Base.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant CREATE2_DEPLOYER_CODE_HASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    /// @notice Smallest batch a third party can split off; a whole remaining balance may always be sent.
    uint256 public constant MIN_DISPATCH = BURN_ALLOCATION_PER_CANDLE;
    address public endpoint;
    address public baseEndpoint;
    address public baseOFT;
    address public baseReceiver;
    uint128 public acknowledgementGas;
    /// @notice Largest batch any caller can dispatch; frozen with the bridge and checked by the receiver against
    ///         the Base token's transfer limits before it signals readiness.
    uint256 public maxBatch;
    bytes32 public receiverSalt;
    bytes public bridgeOptions;
    bytes32 public verificationEvidence;
    bytes32 public configurationHash;
    bytes32 public bridgeTokenCodeHash;
    bytes32 public endpointCodeHash;
    bool public bridgeFrozen;
    bool public receiverReady;
    bool public purchasesEnabled;
    uint256 public totalBurnAllocated;
    uint256 public pendingBurn;
    uint256 public inTransitBurn;
    uint256 public confirmedBurn;
    uint256 public batchCount;

    struct Batch {
        bytes32 guid;
        uint256 amount;
        bool confirmed;
    }
    mapping(uint256 => Batch) public batches;
    mapping(bytes32 => bool) private _usedGuid;

    error BridgeNotReady();
    error ConfigurationFrozen();
    error InvalidBridgeConfiguration();
    error InvalidBatch();
    error IncorrectNativeFee();
    error InvalidBridgeReceipt();
    error UnauthenticatedMessage();
    error InvalidMessage();
    error AlreadyActive();
    error OwnershipRequired();

    event BridgeFrozen(bytes32 indexed configurationHash, bytes32 indexed evidence, address indexed receiver);
    event ReceiverReady(address indexed receiver);
    event PurchasesActivated();
    event BurnDispatched(uint256 indexed batchId, bytes32 indexed guid, uint256 amount, uint256 retainedDust);
    event BurnConfirmed(uint256 indexed batchId, bytes32 indexed guid, uint256 amount);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice One-time owner configuration AFTER independent verification of BOTH chains and default DVN routes.
    /// @dev The receiver address is derived here from the compiled receiver code, this treasury, the fixed
    ///      endpoint ids and the given Base endpoint/adapter/gas/maximum batch/salt. A receiver built from other
    ///      code, for another queue or with other arguments has a different address and can never authenticate.
    ///      `maxBatch_` bounds every dispatch; the derived receiver refuses readiness while the Base token's
    ///      limits would reject one credit of that size.
    function freezeBridge(
        address endpoint_,
        address baseEndpoint_,
        address baseOFT_,
        uint128 receiveGas_,
        uint128 composeGas_,
        uint128 acknowledgementGas_,
        uint256 maxBatch_,
        bytes32 receiverSalt_,
        bytes32 evidence_
    ) external onlyOwner nonReentrant {
        _requireIMD();
        if (bridgeFrozen) revert ConfigurationFrozen();
        if (
            endpoint_.code.length == 0 || baseEndpoint_ == address(0) || baseOFT_ == address(0)
                || baseOFT_ == IMD || baseOFT_ == baseEndpoint_ || evidence_ == bytes32(0)
                || receiveGas_ < 100_000 || composeGas_ < 100_000 || acknowledgementGas_ < 100_000
                || receiveGas_ > 5_000_000 || composeGas_ > 5_000_000 || acknowledgementGas_ > 5_000_000
                || maxBatch_ < MIN_DISPATCH || maxBatch_ % BRIDGE_UNIT != 0
                || maxBatch_ / BRIDGE_UNIT > type(uint64).max
        ) revert InvalidBridgeConfiguration();
        address receiver_ =
            predictReceiver(baseEndpoint_, baseOFT_, acknowledgementGas_, maxBatch_, receiverSalt_);
        if (receiver_ == baseOFT_ || receiver_ == baseEndpoint_) revert InvalidBridgeConfiguration();
        endpoint = endpoint_;
        baseEndpoint = baseEndpoint_;
        baseOFT = baseOFT_;
        baseReceiver = receiver_;
        acknowledgementGas = acknowledgementGas_;
        maxBatch = maxBatch_;
        receiverSalt = receiverSalt_;
        bridgeOptions = BridgeMessages.composeOptions(receiveGas_, composeGas_);
        verificationEvidence = evidence_;
        bridgeTokenCodeHash = IMD.codehash;
        endpointCodeHash = endpoint_.codehash;
        bridgeFrozen = true;
        _checkBridge();
        bytes32 frozenHash = _configurationHash();
        configurationHash = frozenHash;
        emit BridgeFrozen(frozenHash, evidence_, receiver_);
    }

    function _configurationHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                endpoint,
                baseEndpoint,
                ETHEREUM_EID,
                BASE_EID,
                baseOFT,
                baseReceiver,
                acknowledgementGas,
                keccak256(abi.encode(maxBatch, receiverSalt, receiverCreationCodeHash())),
                bridgeOptions,
                verificationEvidence
            )
        );
    }

    function activatePurchases() external onlyOwner nonReentrant {
        if (purchasesEnabled) revert AlreadyActive();
        if (!receiverReady || !_gardenBound()) revert BridgeNotReady();
        _checkBridge();
        purchasesEnabled = true;
        emit PurchasesActivated();
    }

    /// @notice keccak256 of the exact BaseBurnReceiver creation code this treasury accepts.
    function receiverCreationCodeHash() public pure returns (bytes32) {
        return keccak256(type(BaseBurnReceiver).creationCode);
    }

    /// @notice CREATE2 init code hash of the receiver bound to THIS treasury with the fixed endpoint ids.
    function receiverInitCodeHash(
        address baseEndpoint_,
        address baseOFT_,
        uint128 acknowledgementGas_,
        uint256 maxBatch_
    ) public view returns (bytes32) {
        return keccak256(
            bytes.concat(
                type(BaseBurnReceiver).creationCode,
                abi.encode(
                    baseEndpoint_,
                    baseOFT_,
                    address(this),
                    ETHEREUM_EID,
                    BASE_EID,
                    acknowledgementGas_,
                    maxBatch_
                )
            )
        );
    }

    /// @notice Address the deterministic deployer gives that receiver on Base for `salt`.
    function predictReceiver(
        address baseEndpoint_,
        address baseOFT_,
        uint128 acknowledgementGas_,
        uint256 maxBatch_,
        bytes32 salt
    ) public view returns (address) {
        bytes32 initCodeHash = receiverInitCodeHash(baseEndpoint_, baseOFT_, acknowledgementGas_, maxBatch_);
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash))))
        );
    }

    /// @notice Amount that `dispatch(maxAmount, ...)` would send now, its retained dust, fee and next batch id.
    function quoteDispatch(uint256 maxAmount)
        external
        view
        returns (uint256 amount, uint256 dust, uint256 nativeFee, uint256 nextBatchId)
    {
        _checkBridge();
        (amount, dust) = _roundedAmount(maxAmount);
        nextBatchId = batchCount + 1;
        MessagingFee memory fee = IIMDOFT(IMD).quoteSend(_sendParam(amount, nextBatchId), false);
        if (fee.lzTokenFee != 0) revert IncorrectNativeFee();
        nativeFee = fee.nativeFee;
    }

    /// @notice Anyone can pay native gas to send pending IMD ONLY to the frozen receiver via IMD.send.
    /// @dev Sends min(maxAmount, pendingBurn, maxBatch) rounded down to a shared unit, so no caller can create
    ///      a batch larger than the frozen bound the receiver checked against the Base token's limits; a larger
    ///      pending balance simply takes several batches. A batch below MIN_DISPATCH is
    ///      allowed only when it is the whole rounded pending balance, so a third party cannot split pending
    ///      funds into micro-batches. `maxBatchId` is an upper bound: an earlier dispatch by someone else
    ///      does not invalidate a prepared one, it only reduces what is left to send.
    ///      A reverted send leaves all tokens pending. Never resend an in-transit batch.
    function dispatch(uint256 maxAmount, uint256 maxBatchId)
        external
        payable
        nonReentrant
        returns (uint256 batchId)
    {
        if (!purchasesEnabled) revert BridgeNotReady();
        _checkBridge();
        (uint256 amount, uint256 dust) = _roundedAmount(maxAmount);
        batchId = batchCount + 1;
        if (batchId > maxBatchId) revert InvalidBatch();
        SendParam memory params = _sendParam(amount, batchId);
        MessagingFee memory fee = IIMDOFT(IMD).quoteSend(params, false);
        if (fee.lzTokenFee != 0 || msg.value != fee.nativeFee) revert IncorrectNativeFee();
        uint256 beforeBalance = IERC20(IMD).balanceOf(address(this));
        pendingBurn -= amount;
        inTransitBurn += amount;
        batchCount = batchId;
        batches[batchId].amount = amount;
        (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt) =
            IIMDOFT(IMD).send{value: msg.value}(params, fee, msg.sender);
        if (
            receipt.guid == bytes32(0) || _usedGuid[receipt.guid] || oftReceipt.amountSentLD != amount
                || oftReceipt.amountReceivedLD != amount || receipt.fee.nativeFee != fee.nativeFee
                || receipt.fee.lzTokenFee != 0
                || IERC20(IMD).balanceOf(address(this)) != beforeBalance - amount
        ) {
            revert InvalidBridgeReceipt();
        }
        _usedGuid[receipt.guid] = true;
        batches[batchId].guid = receipt.guid;
        emit BurnDispatched(batchId, receipt.guid, amount, dust);
    }

    /// @notice LayerZero V2 receiver ABI. Only the frozen endpoint and derived Base receiver may acknowledge.
    function lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        _requireEthereum();
        if (
            !bridgeFrozen || msg.sender != endpoint || endpoint.codehash != endpointCodeHash
                || origin.srcEid != BASE_EID || origin.sender != BridgeMessages.addressWord(baseReceiver)
        ) revert UnauthenticatedMessage();
        if (msg.value != 0 || message.length != 128) revert InvalidMessage();
        (uint8 kind, uint256 batchId, bytes32 guid, uint256 amount) =
            abi.decode(message, (uint8, uint256, bytes32, uint256));
        if (kind == BridgeMessages.READY) {
            // Only the derived receiver code can send this, after checking its token, adapter, endpoint,
            // reciprocal peer, transfer restrictions and burn availability.
            if (batchId != 0 || guid != BridgeMessages.addressWord(baseOFT) || amount != 8453) {
                revert InvalidMessage();
            }
            if (!receiverReady) {
                receiverReady = true;
                emit ReceiverReady(baseReceiver);
            }
        } else if (kind == BridgeMessages.BURNED) {
            Batch storage batch = batches[batchId];
            if (batch.guid == bytes32(0) || batch.guid != guid || batch.amount != amount) {
                revert InvalidBridgeReceipt();
            }
            if (!batch.confirmed) {
                batch.confirmed = true;
                inTransitBurn -= amount;
                confirmedBurn += amount;
                emit BurnConfirmed(batchId, guid, amount);
            }
        } else {
            revert InvalidMessage();
        }
    }

    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return bridgeFrozen && origin.srcEid == BASE_EID
            && origin.sender == BridgeMessages.addressWord(baseReceiver);
    }

    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0; // unordered, replay protected by batch/GUID
    }

    function totalSupplyBurned() external view returns (uint256) {
        return confirmedBurn;
    }

    function pendingDust() external view returns (uint256) {
        return pendingBurn % BRIDGE_UNIT;
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _checkBridge() internal view {
        _requireIMD();
        if (!bridgeFrozen) revert BridgeNotReady();
        IIMDOFT oft = IIMDOFT(IMD);
        (bytes4 interfaceId, uint64 version) = oft.oftVersion();
        if (
            IMD.codehash != bridgeTokenCodeHash || endpoint.codehash != endpointCodeHash
                || oft.endpoint() != endpoint || IBridgeEndpoint(endpoint).eid() != ETHEREUM_EID
                || oft.token() != IMD || oft.approvalRequired()
                || oft.peers(BASE_EID) != BridgeMessages.addressWord(baseOFT)
                || oft.decimalConversionRate() != BRIDGE_UNIT || oft.sharedDecimals() != 6
                || interfaceId != 0x02e49c2c || version != 1
        ) revert InvalidBridgeConfiguration();
    }

    function _roundedAmount(uint256 maxAmount) private view returns (uint256 amount, uint256 dust) {
        uint256 pending = pendingBurn;
        uint256 capped = maxAmount > pending ? pending : maxAmount;
        if (capped > maxBatch) capped = maxBatch;
        amount = capped / BRIDGE_UNIT * BRIDGE_UNIT;
        dust = capped - amount;
        if (amount == 0 || amount / BRIDGE_UNIT > type(uint64).max) revert InvalidBatch();
        if (amount < MIN_DISPATCH && amount != pending / BRIDGE_UNIT * BRIDGE_UNIT) revert InvalidBatch();
    }

    function _sendParam(uint256 amount, uint256 batchId) private view returns (SendParam memory) {
        return SendParam(
            BASE_EID,
            BridgeMessages.addressWord(baseReceiver),
            amount,
            amount,
            bridgeOptions,
            abi.encode(BridgeMessages.VERSION, batchId, amount),
            bytes("")
        );
    }
    function _gardenBound() internal view virtual returns (bool);
}
