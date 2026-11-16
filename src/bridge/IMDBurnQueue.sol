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

/// @notice Restricted direct IMD OFT sender and authenticated Base burn receipt ledger.
/// @dev No approval, withdrawal, delegate, arbitrary-call or owner confirmation path exists.
abstract contract IMDBurnQueue is GardenEconomy, Ownable2Step, ReentrancyGuard {
    uint256 public constant BRIDGE_UNIT = 1e12; // verified 18 local / 6 shared decimals
    address public endpoint;
    uint32 public ethereumEid;
    uint32 public baseEid;
    address public baseOFT;
    address public baseReceiver;
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
    /// @dev The remote receiver and the existing bridge's own administrative settings require external review.
    function freezeBridge(
        address endpoint_,
        uint32 ethereumEid_,
        uint32 baseEid_,
        address baseOFT_,
        address receiver_,
        uint128 receiveGas_,
        uint128 composeGas_,
        bytes32 evidence_
    ) external onlyOwner nonReentrant {
        _requireIMD();
        if (bridgeFrozen) revert ConfigurationFrozen();
        if (
            endpoint_.code.length == 0 || baseOFT_ == address(0) || receiver_ == address(0)
                || receiver_ == baseOFT_ || ethereumEid_ == 0 || baseEid_ == 0 || ethereumEid_ == baseEid_
                || evidence_ == bytes32(0) || receiveGas_ < 100_000 || composeGas_ < 100_000
                || receiveGas_ > 5_000_000 || composeGas_ > 5_000_000
        ) revert InvalidBridgeConfiguration();
        endpoint = endpoint_;
        ethereumEid = ethereumEid_;
        baseEid = baseEid_;
        baseOFT = baseOFT_;
        baseReceiver = receiver_;
        bridgeOptions = BridgeMessages.composeOptions(receiveGas_, composeGas_);
        verificationEvidence = evidence_;
        bridgeTokenCodeHash = IMD.codehash;
        endpointCodeHash = endpoint_.codehash;
        bridgeFrozen = true;
        _checkBridge();
        configurationHash = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                endpoint_,
                ethereumEid_,
                baseEid_,
                baseOFT_,
                receiver_,
                bridgeOptions,
                evidence_
            )
        );
        emit BridgeFrozen(configurationHash, evidence_, receiver_);
    }

    function activatePurchases() external onlyOwner nonReentrant {
        if (purchasesEnabled) revert AlreadyActive();
        if (!receiverReady || !_gardenBound()) revert BridgeNotReady();
        _checkBridge();
        purchasesEnabled = true;
        emit PurchasesActivated();
    }

    /// @notice Rounded amount and a fresh native fee quote. No gas is charged to the 30% IMD allocation.
    function quoteDispatch(uint256 requestedAmount)
        external
        view
        returns (uint256 amount, uint256 dust, uint256 nativeFee, uint256 nextBatchId)
    {
        _checkBridge();
        amount = _roundedAmount(requestedAmount);
        dust = requestedAmount - amount;
        nextBatchId = batchCount + 1;
        MessagingFee memory fee = IIMDOFT(IMD).quoteSend(_sendParam(amount, nextBatchId), false);
        if (fee.lzTokenFee != 0) revert IncorrectNativeFee();
        nativeFee = fee.nativeFee;
    }

    /// @notice Anyone can pay native gas to send pending IMD ONLY to the frozen receiver via IMD.send.
    /// @dev A reverted send leaves the same batch ID and all tokens pending. Never resend an in-transit batch.
    function dispatch(uint256 requestedAmount, uint256 expectedBatchId)
        external
        payable
        nonReentrant
        returns (uint256 batchId)
    {
        if (!purchasesEnabled) revert BridgeNotReady();
        _checkBridge();
        uint256 amount = _roundedAmount(requestedAmount);
        batchId = batchCount + 1;
        if (expectedBatchId != batchId) revert InvalidBatch();
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
        emit BurnDispatched(batchId, receipt.guid, amount, requestedAmount - amount);
    }

    /// @notice LayerZero V2 receiver ABI. Only the frozen endpoint and Base receiver may acknowledge burns.
    function lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata)
        external
        payable
        nonReentrant
    {
        _requireEthereum();
        if (
            !bridgeFrozen || msg.sender != endpoint || endpoint.codehash != endpointCodeHash
                || origin.srcEid != baseEid || origin.sender != BridgeMessages.addressWord(baseReceiver)
        ) revert UnauthenticatedMessage();
        if (msg.value != 0 || message.length != 128) revert InvalidMessage();
        (uint8 kind, uint256 batchId, bytes32 guid, uint256 amount) =
            abi.decode(message, (uint8, uint256, bytes32, uint256));
        if (kind == BridgeMessages.READY) {
            // The receiver checks its token, official adapter, endpoint, peer and burn availability before sending.
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
        return
            bridgeFrozen && origin.srcEid == baseEid
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
                || oft.endpoint() != endpoint || IBridgeEndpoint(endpoint).eid() != ethereumEid
                || oft.token() != IMD || oft.approvalRequired()
                || oft.peers(baseEid) != BridgeMessages.addressWord(baseOFT)
                || oft.decimalConversionRate() != BRIDGE_UNIT || oft.sharedDecimals() != 6
                || interfaceId != 0x02e49c2c || version != 1
        ) revert InvalidBridgeConfiguration();
    }

    function _roundedAmount(uint256 requestedAmount) private view returns (uint256 amount) {
        if (requestedAmount > pendingBurn) revert InvalidBatch();
        amount = requestedAmount / BRIDGE_UNIT * BRIDGE_UNIT;
        if (amount == 0 || amount / BRIDGE_UNIT > type(uint64).max) revert InvalidBatch();
    }

    function _sendParam(uint256 amount, uint256 batchId) private view returns (SendParam memory) {
        return SendParam(
            baseEid,
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
