// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GardenEconomy} from "./GardenEconomy.sol";
import {WishGardenTreasury} from "./WishGardenTreasury.sol";
import {WishText} from "./WishText.sol";

/// @notice Paid-only permanent candles. Legacy remains the sole lifetime free-claim ledger.
contract WishGarden is GardenEconomy, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    address public constant LEGACY_GARDEN = 0xAaBd6A747359F5478803EFA7B51E929e62EC4cA2;
    uint8 public constant STYLE_COUNT = 7;
    uint256 public constant MAX_PAGE_SIZE = 100;
    uint256 public constant CANDLE_ID_BASE = 1 << 255;

    struct Candle {
        address purchaser;
        uint64 createdAt;
        uint8 style;
        bool freeClaim;
        uint256 position;
        uint256 nftTokenId;
    }
    WishGardenTreasury public immutable treasury;
    uint256 public totalCandles;
    uint256 public paidCandles;
    mapping(uint256 => Candle) private _candles;
    mapping(address => uint256[]) private _purchaserCandles;
    // One immutable full text per purchase, referenced by every candle in that batch.
    mapping(uint256 => string) private _batchWishes;
    mapping(uint256 => uint256) public wishBatch;
    error InvalidStyle(uint8 style);
    error PurchasesDisabled();
    error CandleNotFound(uint256 candleId);
    error InvalidPage();
    error NamespaceExhausted();
    error OwnershipRequired();
    event CandleCreated(
        uint256 indexed candleId,
        address indexed purchaser,
        uint256 position,
        uint8 style,
        uint64 createdAt,
        bool freeClaim,
        uint256 nftTokenId
    );
    event CandlesPurchased(
        address indexed purchaser,
        uint256 indexed firstCandleId,
        uint256 quantity,
        uint8 style,
        uint256 totalIMD
    );
    event WishPublished(uint256 indexed firstCandleId, address indexed author, uint256 quantity, string text);

    constructor(address owner_, address treasury_) Ownable(owner_) {
        if (treasury_ == address(0) || treasury_ == address(this)) revert InvalidAddress();
        treasury = WishGardenTreasury(treasury_);
    }

    function buyCandles(uint256 quantity, uint8 style) external nonReentrant returns (uint256 firstCandleId) {
        return _buy(quantity, style, "", false);
    }

    /// @notice All candles in this purchase receive the same optional immutable wish. Use separate purchases for different texts.
    function buyCandlesWithWish(
        uint256 quantity,
        uint8 style,
        string calldata text,
        bool publicForeverAcknowledged
    ) external nonReentrant returns (uint256 firstCandleId) {
        return _buy(quantity, style, text, publicForeverAcknowledged);
    }

    function _buy(uint256 quantity, uint8 style, string memory text, bool acknowledged)
        private
        returns (uint256 firstCandleId)
    {
        _checkQuantity(quantity);
        if (style >= STYLE_COUNT) revert InvalidStyle(style);
        WishText.validate(text, acknowledged);
        _requireIMD();
        if (
            address(treasury).code.length == 0 || treasury.garden() != address(this)
                || !treasury.purchasesEnabled()
        ) {
            revert PurchasesDisabled();
        }
        // Reserve the final uint256 value for an exclusive pagination cursor.
        if (totalCandles + quantity >= CANDLE_ID_BASE - 1) revert NamespaceExhausted();
        uint256 payment = CANDLE_PRICE * quantity;
        firstCandleId = CANDLE_ID_BASE + totalCandles + 1;
        paidCandles += quantity;
        uint64 createdAt = block.timestamp.toUint64();
        bool hasWish = bytes(text).length != 0;
        if (hasWish) _batchWishes[firstCandleId] = text;
        for (uint256 i; i < quantity; ++i) {
            uint256 id = CANDLE_ID_BASE + ++totalCandles;
            _candles[id] = Candle(msg.sender, createdAt, style, false, id - 1, 0);
            _purchaserCandles[msg.sender].push(id);
            if (hasWish) wishBatch[id] = firstCandleId;
            emit CandleCreated(id, msg.sender, id - 1, style, createdAt, false, 0);
        }
        IERC20 token = IERC20(IMD);
        uint256 gardenBefore = token.balanceOf(address(this));
        uint256 purchaserBefore = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), payment);
        if (
            token.balanceOf(address(this)) != gardenBefore + payment
                || token.balanceOf(msg.sender) + payment != purchaserBefore
        ) {
            revert InexactTransfer();
        }
        uint256 treasuryBefore = token.balanceOf(address(treasury));
        token.safeTransfer(address(treasury), payment);
        if (
            token.balanceOf(address(this)) != gardenBefore
                || token.balanceOf(address(treasury)) != treasuryBefore + payment
        ) {
            revert InexactTransfer();
        }
        treasury.recordPayment(msg.sender, firstCandleId, quantity);
        emit CandlesPurchased(msg.sender, firstCandleId, quantity, style, payment);
        if (hasWish) emit WishPublished(firstCandleId, msg.sender, quantity, text);
    }

    function getCandle(uint256 candleId) public view returns (Candle memory) {
        _requireCandle(candleId);
        return _candles[candleId];
    }

    function wishOf(uint256 candleId) external view returns (address author, string memory text) {
        _requireCandle(candleId);
        return (_candles[candleId].purchaser, _batchWishes[wishBatch[candleId]]);
    }

    /// @notice Canonical global identifier; clients MUST also namespace legacy records by their contract address.
    function candleKey(uint256 candleId) external view returns (bytes32) {
        _requireCandle(candleId);
        return keccak256(abi.encode(CHAIN_ID, address(this), candleId));
    }

    function candleCountOf(address purchaser) external view returns (uint256) {
        return _purchaserCandles[purchaser].length;
    }

    function candleIdsOf(address purchaser, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextOffset)
    {
        uint256 length = _purchaserCandles[purchaser].length;
        if (limit == 0 || limit > MAX_PAGE_SIZE || offset > length) revert InvalidPage();
        uint256 count = length - offset;
        if (count > limit) count = limit;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _purchaserCandles[purchaser][offset + i];
        }
        nextOffset = offset + count;
    }

    /// @notice Start at CANDLE_ID_BASE + 1; nextId is an exclusive cursor, not a count.
    function getCandles(uint256 firstId, uint256 limit)
        external
        view
        returns (Candle[] memory records, uint256 nextId)
    {
        uint256 end = CANDLE_ID_BASE + totalCandles + 1;
        if (limit == 0 || limit > MAX_PAGE_SIZE || firstId <= CANDLE_ID_BASE || firstId > end) {
            revert InvalidPage();
        }
        uint256 count = end - firstId;
        if (count > limit) count = limit;
        records = new Candle[](count);
        for (uint256 i; i < count; ++i) {
            records[i] = _candles[firstId + i];
        }
        nextId = firstId + count;
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _requireCandle(uint256 id) private view {
        if (id <= CANDLE_ID_BASE || id - CANDLE_ID_BASE > totalCandles) revert CandleNotFound(id);
    }
}
