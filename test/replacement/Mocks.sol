// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {AdversarialIMD} from "../helpers/AdversarialIMD.sol";
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    MessagingParams
} from "../../src/bridge/IMDBridgeInterfaces.sol";

contract MockEndpoint {
    uint32 public eid;
    uint256 public nativeFee = 0.001 ether;
    uint64 public nonce;
    bool public fail;
    bytes public lastMessage;
    bytes public lastOptions;
    bytes32 public lastReceiver;
    uint32 public lastDstEid;
    address public lastSender;
    address public lastComposeTo;
    bytes32 public lastComposeGuid;
    bytes public lastComposeMessage;

    /// @dev EndpointV2.sendCompose as called by the real adapter runtime after it credits the recipient.
    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external {
        require(index == 0, "mock compose index");
        lastComposeTo = to;
        lastComposeGuid = guid;
        lastComposeMessage = message;
    }

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function setFail(bool flag) external {
        fail = flag;
    }

    function setFee(uint256 fee) external {
        nativeFee = fee;
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, 0);
    }

    function send(MessagingParams calldata p, address) external payable returns (MessagingReceipt memory) {
        require(!fail, "mock failed ack");
        require(msg.value == nativeFee, "mock fee");
        lastMessage = p.message;
        lastOptions = p.options;
        lastReceiver = p.receiver;
        lastDstEid = p.dstEid;
        lastSender = msg.sender;
        return
            MessagingReceipt(keccak256(abi.encode(address(this), ++nonce)), nonce, MessagingFee(nativeFee, 0));
    }
}

contract MockIMDOFT is AdversarialIMD {
    address public endpoint;
    address public peer;
    uint256 public nativeFee;
    uint8 public sendMode;
    uint64 public nonce;
    uint256 public lastAmount;
    bytes32 public lastRecipient;
    bytes public lastCompose;
    bytes public lastOptions;
    address public refund;

    function setup(address endpoint_, address peer_) external {
        endpoint = endpoint_;
        peer = peer_;
        nativeFee = 0.001 ether;
    }

    function setPeer(address peer_) external {
        peer = peer_;
    }

    function setSendMode(uint8 mode) external {
        sendMode = mode;
    }

    function token() external view returns (address) {
        return address(this);
    }

    function approvalRequired() external pure returns (bool) {
        return false;
    }

    function peers(uint32) external view returns (bytes32) {
        return bytes32(uint256(uint160(peer)));
    }

    function decimalConversionRate() external pure returns (uint256) {
        return 1e12;
    }

    function sharedDecimals() external pure returns (uint8) {
        return 6;
    }

    function oftVersion() external pure returns (bytes4, uint64) {
        return (0x02e49c2c, 1);
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, 0);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address refund_)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        require(sendMode != 1, "mock send failed");
        require(msg.value == nativeFee && fee.nativeFee == nativeFee && fee.lzTokenFee == 0, "mock fee");
        require(p.amountLD == p.minAmountLD && p.oftCmd.length == 0, "unsafe parameters");
        lastAmount = p.amountLD;
        lastRecipient = p.to;
        lastCompose = p.composeMsg;
        lastOptions = p.extraOptions;
        refund = refund_;
        if (sendMode != 4) _burn(msg.sender, p.amountLD);
        bytes32 guid = sendMode == 5 ? bytes32(uint256(1)) : keccak256(abi.encode(address(this), ++nonce));
        return
            (MessagingReceipt(guid, nonce, fee), OFTReceipt(p.amountLD, p.amountLD - (sendMode == 2 ? 1 : 0)));
    }
}

contract MockBaseIMD is AdversarialIMD {
    uint8 public burnMode;
    bool public limitsInEffect;
    uint256 public maxWallet;
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public _isExcludedMaxTransactionAmount;
    mapping(address => bool) public isExcludedFromFees;
    bool public tradingPaused; // inverted so the etched (storage-less) default is "trading active"

    function tradingActive() external view returns (bool) {
        return !tradingPaused;
    }

    function setTradingPaused(bool flag) external {
        tradingPaused = flag;
    }

    function setExcludedFromFees(address account, bool flag) external {
        isExcludedFromFees[account] = flag;
    }

    function setBurnMode(uint8 mode) external {
        burnMode = mode;
    }

    function setBlacklisted(address account, bool flag) external {
        isBlacklisted[account] = flag;
    }

    function setLimits(bool inEffect, uint256 wallet) external {
        limitsInEffect = inEffect;
        maxWallet = wallet;
    }

    function setExcluded(address account, bool flag) external {
        _isExcludedMaxTransactionAmount[account] = flag;
    }

    function burn(uint256 amount) external {
        require(burnMode != 1, "mock burn failed");
        if (burnMode == 2) return;
        _burn(msg.sender, amount);
        if (burnMode == 3) _mint(address(this), amount);
    }
}

contract MockBaseAdapter {
    address public endpoint;
    address public token;
    address public peer;

    constructor(address endpoint_, address token_, address peer_) {
        endpoint = endpoint_;
        token = token_;
        peer = peer_;
    }

    function peers(uint32) external view returns (bytes32) {
        return bytes32(uint256(uint160(peer)));
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    function decimalConversionRate() external pure returns (uint256) {
        return 1e12;
    }

    function sharedDecimals() external pure returns (uint8) {
        return 6;
    }

    function oftVersion() external pure returns (bytes4, uint64) {
        return (0x02e49c2c, 1);
    }
}
