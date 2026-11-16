// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {GardenEconomy} from "../../src/GardenEconomy.sol";
import {LegacyWishGardenTreasury} from "./LegacyWishGardenTreasury.sol";

/// @notice Permanent, nontransferable candle records paid in existing Ethereum IMD or claimed by NFT ID.
contract LegacyWishGarden is GardenEconomy, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // Resolved from official IMD docs and verified Ethereum runtime; never selected by a claimant.
    address public constant OFFICIAL_COLLECTION = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    bytes32 public constant COLLECTION_CODE_HASH =
        0x68d046e0bfb8185d9db0a9a7ed57420f22dfc38321c9c91453a001a47668c530;
    uint8 public constant STYLE_COUNT = 7;
    uint256 public constant MAX_PAGE_SIZE = 100;

    /// @dev Style order: Purity, Hope, Love, Success, Health, Wealth, Happiness.
    ///      Position is the immutable zero-based slot, equal to candle ID minus one.
    struct Candle {
        address purchaser;
        uint64 createdAt;
        uint8 style;
        bool freeClaim;
        uint256 position;
        uint256 nftTokenId;
    }

    LegacyWishGardenTreasury public immutable treasury;
    uint256 public totalCandles;
    uint256 public paidCandles;
    uint256 public freeCandles;
    bool public collectionConfirmed;
    bytes32 public collectionEvidenceHash;

    mapping(uint256 candleId => Candle) private _candles;
    mapping(address purchaser => uint256[]) private _purchaserCandles;
    // A zero value means unused, since candle IDs start at 1. NFT token ID 0 is valid.
    mapping(uint256 tokenId => uint256 candleId) public nftClaimedCandle;

    error InvalidStyle(uint8 style);
    error TreasuryNotConfigured();
    error CollectionNotConfirmed();
    error CollectionAlreadyConfirmed();
    error CollectionVerificationFailed();
    error MissingVerificationEvidence();
    error NFTAlreadyClaimed(uint256 tokenId);
    error NotNFTOwner(uint256 tokenId);
    error CandleNotFound(uint256 candleId);
    error InvalidPage();
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
    event FreeCandleClaimed(
        address indexed purchaser, uint256 indexed tokenId, uint256 indexed candleId, address collection
    );
    event OfficialCollectionConfirmed(
        address indexed collection, address indexed confirmedBy, bytes32 codeHash, bytes32 evidenceHash
    );

    constructor(address owner_, address treasury_) Ownable(owner_) {
        if (treasury_ == address(0) || treasury_ == address(this)) revert InvalidAddress();
        treasury = LegacyWishGardenTreasury(treasury_);
    }

    /// @notice Purchase 1..50 identical-style candles, exactly 1 IMD each; larger orders use more transactions.
    /// @dev Approve exactly quantity * CANDLE_PRICE to this contract. Never accepts native ETH.
    function buyCandles(uint256 quantity, uint8 style) external nonReentrant returns (uint256 firstCandleId) {
        _checkQuantity(quantity);
        _checkStyle(style);
        _requireIMD();
        if (address(treasury).code.length == 0 || treasury.garden() != address(this)) {
            revert TreasuryNotConfigured();
        }
        uint256 payment = CANDLE_PRICE * quantity;
        firstCandleId = totalCandles + 1;
        paidCandles += quantity;
        for (uint256 i; i < quantity; ++i) {
            _createCandle(msg.sender, style, false, 0);
        }

        IERC20 token = IERC20(IMD);
        uint256 gardenBefore = token.balanceOf(address(this));
        uint256 purchaserBefore = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), payment);
        if (
            token.balanceOf(address(this)) != gardenBefore + payment
                || token.balanceOf(msg.sender) + payment != purchaserBefore
        ) revert InexactTransfer();

        uint256 treasuryBefore = token.balanceOf(address(treasury));
        token.safeTransfer(address(treasury), payment);
        if (
            token.balanceOf(address(this)) != gardenBefore
                || token.balanceOf(address(treasury)) != treasuryBefore + payment
        ) revert InexactTransfer();
        treasury.recordPayment(msg.sender, firstCandleId, quantity);
        emit CandlesPurchased(msg.sender, firstCandleId, quantity, style, payment);
    }

    /// @notice Owner attests the official collection verification once. No arbitrary address is accepted.
    /// @param evidenceHash Keccak-256 of the reviewed verification evidence; must be nonzero.
    function confirmOfficialCollection(bytes32 evidenceHash) external nonReentrant onlyOwner {
        _requireEthereum();
        if (collectionConfirmed) revert CollectionAlreadyConfirmed();
        if (evidenceHash == bytes32(0)) revert MissingVerificationEvidence();
        _requireCollectionCode();
        IERC165 collection = IERC165(OFFICIAL_COLLECTION);
        if (
            !collection.supportsInterface(type(IERC165).interfaceId)
                || !collection.supportsInterface(type(IERC721).interfaceId)
                || collection.supportsInterface(0xffffffff)
        ) revert CollectionVerificationFailed();
        collectionConfirmed = true;
        collectionEvidenceHash = evidenceHash;
        emit OfficialCollectionConfirmed(OFFICIAL_COLLECTION, msg.sender, COLLECTION_CODE_HASH, evidenceHash);
    }

    /// @notice Claim one free candle as the current owner of an unused official NFT ID. Costs zero IMD.
    function claimFreeCandle(uint256 tokenId, uint8 style) external nonReentrant returns (uint256 candleId) {
        _requireClaimsEnabled();
        _checkStyle(style);
        return _claim(tokenId, style);
    }

    /// @notice Claim up to 50 NFTs in one atomic transaction. A duplicate or ineligible ID reverts all.
    function claimFreeCandles(uint256[] calldata tokenIds, uint8 style)
        external
        nonReentrant
        returns (uint256 firstCandleId)
    {
        _requireClaimsEnabled();
        _checkQuantity(tokenIds.length);
        _checkStyle(style);
        firstCandleId = totalCandles + 1;
        for (uint256 i; i < tokenIds.length; ++i) {
            _claim(tokenIds[i], style);
        }
    }

    /// @notice An explicit disabled reason for frontends; never report success before a confirmed receipt.
    function freeClaimsStatus() external view returns (bool enabled, string memory reason) {
        if (block.chainid != CHAIN_ID) return (false, "Ethereum mainnet required");
        if (!collectionConfirmed) {
            return (false, "Owner has not confirmed the verified official NFT collection");
        }
        if (OFFICIAL_COLLECTION.codehash != COLLECTION_CODE_HASH) {
            return (false, "Official NFT runtime does not match the verified code");
        }
        return (true, "");
    }

    function getCandle(uint256 candleId) external view returns (Candle memory) {
        if (candleId == 0 || candleId > totalCandles) revert CandleNotFound(candleId);
        return _candles[candleId];
    }

    function candleCountOf(address purchaser) external view returns (uint256) {
        return _purchaserCandles[purchaser].length;
    }

    /// @notice Bounded purchaser index for walletless history and "Find my candles" after reload.
    function candleIdsOf(address purchaser, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextOffset)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert InvalidPage();
        uint256 length = _purchaserCandles[purchaser].length;
        if (offset > length) revert InvalidPage();
        uint256 count = length - offset;
        if (count > limit) count = limit;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _purchaserCandles[purchaser][offset + i];
        }
        nextOffset = offset + count;
    }

    /// @notice Bounded global records. A candle's ID is its position + 1. Start with ID 1.
    function getCandles(uint256 firstId, uint256 limit)
        external
        view
        returns (Candle[] memory records, uint256 nextId)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE || firstId == 0 || firstId > totalCandles + 1) {
            revert InvalidPage();
        }
        uint256 count = totalCandles + 1 - firstId;
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

    function _claim(uint256 tokenId, uint8 style) private returns (uint256 candleId) {
        if (nftClaimedCandle[tokenId] != 0) revert NFTAlreadyClaimed(tokenId);
        try IERC721(OFFICIAL_COLLECTION).ownerOf(tokenId) returns (address tokenOwner) {
            if (tokenOwner != msg.sender) revert NotNFTOwner(tokenId);
        } catch {
            revert NotNFTOwner(tokenId);
        }
        candleId = totalCandles + 1;
        nftClaimedCandle[tokenId] = candleId;
        ++freeCandles;
        _createCandle(msg.sender, style, true, tokenId);
        emit FreeCandleClaimed(msg.sender, tokenId, candleId, OFFICIAL_COLLECTION);
    }

    function _createCandle(address purchaser, uint8 style, bool freeClaim, uint256 tokenId) private {
        uint256 candleId = ++totalCandles;
        uint256 position = candleId - 1;
        uint64 createdAt = block.timestamp.toUint64();
        _candles[candleId] = Candle(purchaser, createdAt, style, freeClaim, position, tokenId);
        _purchaserCandles[purchaser].push(candleId);
        emit CandleCreated(candleId, purchaser, position, style, createdAt, freeClaim, tokenId);
    }

    function _checkStyle(uint8 style) private pure {
        if (style >= STYLE_COUNT) revert InvalidStyle(style);
    }

    function _requireCollectionCode() private view {
        if (OFFICIAL_COLLECTION.codehash != COLLECTION_CODE_HASH) revert CollectionVerificationFailed();
    }

    function _requireClaimsEnabled() private view {
        _requireEthereum();
        if (!collectionConfirmed) revert CollectionNotConfirmed();
        _requireCollectionCode();
    }
}
