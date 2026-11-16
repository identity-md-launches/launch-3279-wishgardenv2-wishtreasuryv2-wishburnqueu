// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GardenEconomy} from "./GardenEconomy.sol";
import {WishText} from "./WishText.sol";
import {ILegacyWishGarden, ILegacyTreasury} from "./interfaces/ILegacyWishGarden.sol";

/// @notice Immutable missing wishes for the fixed legacy garden; NEVER creates or mutates a candle or NFT claim.
contract LegacyWishRegistry is GardenEconomy, ReentrancyGuard {
    address public constant LEGACY_GARDEN = 0xAaBd6A747359F5478803EFA7B51E929e62EC4cA2;
    address public constant LEGACY_TREASURY = 0x929A062e0Ab6266534F1Ce573ba34cA7980207aA;

    struct Wish {
        address author;
        string text;
    }
    mapping(uint256 => Wish) private _wishes;
    error NotLegacyPurchaser();
    error WishAlreadyRegistered();
    error EmptyWish();
    event LegacyWishPublished(
        address indexed garden, uint256 indexed candleId, address indexed author, string text
    );

    function registerWish(uint256 candleId, string calldata text, bool publicForeverAcknowledged)
        external
        nonReentrant
    {
        _requireEthereum();
        if (_wishes[candleId].author != address(0)) revert WishAlreadyRegistered();
        if (bytes(text).length == 0) revert EmptyWish();
        WishText.validate(text, publicForeverAcknowledged);
        ILegacyWishGarden.Candle memory candle = ILegacyWishGarden(LEGACY_GARDEN).getCandle(candleId);
        if (candle.purchaser != msg.sender) revert NotLegacyPurchaser();
        _wishes[candleId] = Wish(msg.sender, text);
        emit LegacyWishPublished(LEGACY_GARDEN, candleId, msg.sender, text);
    }

    function wishOf(uint256 candleId) external view returns (address author, string memory text) {
        Wish storage wish = _wishes[candleId];
        return (wish.author, wish.text);
    }

    function legacyCandle(uint256 candleId) external view returns (ILegacyWishGarden.Candle memory) {
        return ILegacyWishGarden(LEGACY_GARDEN).getCandle(candleId);
    }

    function legacyGardenBalance() external view returns (uint256) {
        return IERC20(IMD).balanceOf(LEGACY_GARDEN);
    }

    function candleKey(uint256 candleId) external pure returns (bytes32) {
        return keccak256(abi.encode(CHAIN_ID, LEGACY_GARDEN, candleId));
    }

    /// @notice Read-through of old custody. Sink funds are LOCKED, not supply burned. Donations are included in held balances.
    function legacyFunds()
        external
        view
        returns (
            address sink,
            uint256 treasuryHeld,
            uint256 sinkLocked,
            uint256 payments,
            uint256 allocatedToSink,
            uint256 ecosystem,
            uint256 operations,
            uint256 founder
        )
    {
        ILegacyTreasury old = ILegacyTreasury(LEGACY_TREASURY);
        sink = old.burnSink();
        IERC20 token = IERC20(IMD);
        return (
            sink,
            token.balanceOf(LEGACY_TREASURY),
            token.balanceOf(sink),
            old.totalPayments(),
            old.totalIMDLocked(),
            old.ecosystemBalance(),
            old.operationsBalance(),
            old.founderBalance()
        );
    }
}
