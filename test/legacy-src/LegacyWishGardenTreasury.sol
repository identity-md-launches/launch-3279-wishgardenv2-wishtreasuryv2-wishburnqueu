// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GardenEconomy} from "../../src/GardenEconomy.sol";
import {LegacyWishGardenBurnSink} from "./LegacyWishGardenBurnSink.sol";
import {IWishGarden} from "../../src/interfaces/IWishGarden.sol";

/// @notice Separate IMD allocation ledger. Only the ecosystem bucket is managed by the owner.
/// @dev Operations/founder may claim only their own fixed bucket to their immutable recipient.
contract LegacyWishGardenTreasury is GardenEconomy, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Bucket {
        Ecosystem,
        Operations,
        Founder
    }

    address public immutable burnSink;
    address public immutable operationsRecipient;
    address public immutable founderRecipient;
    address public garden;

    uint256 public ecosystemBalance;
    uint256 public operationsBalance;
    uint256 public founderBalance;
    uint256 public totalPayments;
    uint256 public totalIMDLocked;
    uint256 public totalEcosystemWithdrawn;
    uint256 public totalOperationsClaimed;
    uint256 public totalFounderClaimed;

    error GardenAlreadyBound();
    error GardenNotConfigured();
    error InvalidGarden();
    error OnlyGarden();
    error InvalidBurnSink();
    error InsufficientFunding();
    error InsufficientBucketBalance();
    error UnauthorizedBeneficiary();
    error InvalidWithdrawal();
    error OwnershipRequired();

    event GardenBound(address indexed garden);
    event PaymentAllocated(
        address indexed purchaser,
        uint256 indexed firstCandleId,
        uint256 quantity,
        uint256 payment,
        uint256 locked,
        uint256 ecosystem,
        uint256 operations,
        uint256 founder
    );
    event BurnAllocationLocked(address indexed sink, uint256 amount, uint256 cumulativeLocked);
    event BucketWithdrawn(
        Bucket indexed bucket, address indexed caller, address indexed destination, uint256 amount
    );

    /// @dev No dependency is called during construction, so factory deployment works on an empty chain.
    constructor(address owner_, address burnSink_, address operationsRecipient_, address founderRecipient_)
        Ownable(owner_)
    {
        if (
            burnSink_ == address(0) || burnSink_ == address(this) || operationsRecipient_ == address(0)
                || founderRecipient_ == address(0) || operationsRecipient_ == address(this)
                || founderRecipient_ == address(this) || operationsRecipient_ == burnSink_
                || founderRecipient_ == burnSink_
        ) revert InvalidAddress();
        burnSink = burnSink_;
        operationsRecipient = operationsRecipient_;
        founderRecipient = founderRecipient_;
    }

    /// @notice Owner verifies and binds the deployed garden exactly once; purchases are disabled until then.
    function bindGarden(address garden_) external nonReentrant onlyOwner {
        _requireEthereum();
        if (garden != address(0)) revert GardenAlreadyBound();
        if (garden_ == address(0) || garden_.code.length == 0 || garden_ == address(this)) {
            revert InvalidGarden();
        }
        IWishGarden candidate = IWishGarden(garden_);
        if (candidate.treasury() != address(this) || candidate.owner() != owner() || candidate.IMD() != IMD) {
            revert InvalidGarden();
        }
        _requireBurnSink();
        garden = garden_;
        emit GardenBound(garden_);
    }

    /// @notice Account for a payment already transferred by the bound garden, then lock its 30% atomically.
    function recordPayment(address purchaser, uint256 firstCandleId, uint256 quantity) external nonReentrant {
        if (garden == address(0)) revert GardenNotConfigured();
        if (msg.sender != garden) revert OnlyGarden();
        if (purchaser == address(0) || firstCandleId == 0) revert InvalidAddress();
        _checkQuantity(quantity);
        _requireIMD();
        _requireBurnSink();

        uint256 payment = CANDLE_PRICE * quantity;
        uint256 locked = BURN_ALLOCATION_PER_CANDLE * quantity;
        uint256 ecosystem = ECOSYSTEM_PER_CANDLE * quantity;
        uint256 operations = OPERATIONS_PER_CANDLE * quantity;
        uint256 founder = FOUNDER_PER_CANDLE * quantity;
        IERC20 token = IERC20(IMD);
        uint256 balanceBefore = token.balanceOf(address(this));
        if (balanceBefore < accountedBalance() + payment) revert InsufficientFunding();
        uint256 sinkBefore = token.balanceOf(burnSink);
        uint256 supplyBefore = token.totalSupply();

        ecosystemBalance += ecosystem;
        operationsBalance += operations;
        founderBalance += founder;
        totalPayments += payment;
        totalIMDLocked += locked;

        token.safeTransfer(burnSink, locked);
        if (
            token.balanceOf(address(this)) != balanceBefore - locked
                || token.balanceOf(burnSink) != sinkBefore + locked || token.totalSupply() != supplyBefore
        ) revert InexactTransfer();

        emit BurnAllocationLocked(burnSink, locked, totalIMDLocked);
        emit PaymentAllocated(
            purchaser, firstCandleId, quantity, payment, locked, ecosystem, operations, founder
        );
    }

    function withdrawEcosystem(address destination, uint256 amount) external nonReentrant onlyOwner {
        if (amount > ecosystemBalance) revert InsufficientBucketBalance();
        ecosystemBalance -= amount;
        totalEcosystemWithdrawn += amount;
        _withdraw(Bucket.Ecosystem, destination, amount);
    }

    function claimOperations(uint256 amount) external nonReentrant {
        if (msg.sender != operationsRecipient) revert UnauthorizedBeneficiary();
        if (amount > operationsBalance) revert InsufficientBucketBalance();
        operationsBalance -= amount;
        totalOperationsClaimed += amount;
        _withdraw(Bucket.Operations, operationsRecipient, amount);
    }

    function claimFounder(uint256 amount) external nonReentrant {
        if (msg.sender != founderRecipient) revert UnauthorizedBeneficiary();
        if (amount > founderBalance) revert InsufficientBucketBalance();
        founderBalance -= amount;
        totalFounderClaimed += amount;
        _withdraw(Bucket.Founder, founderRecipient, amount);
    }

    /// @notice Revenue still held here; excludes the permanently locked 30% and unsolicited transfers.
    function accountedBalance() public view returns (uint256) {
        return ecosystemBalance + operationsBalance + founderBalance;
    }

    /// @notice Unsolicited IMD is visible but cannot be withdrawn or relabeled as candle revenue.
    function unallocatedBalance() external view returns (uint256) {
        uint256 held = IERC20(IMD).balanceOf(address(this));
        uint256 accounted = accountedBalance();
        return held > accounted ? held - accounted : 0;
    }

    /// @notice This application's sink transfers reduce circulating availability, not ERC20 totalSupply.
    function totalSupplyBurned() external pure returns (uint256) {
        return 0;
    }

    /// @dev Retain an accountable treasury owner; transferOwnership/acceptOwnership remain available.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    function _requireBurnSink() private view {
        if (burnSink.codehash != keccak256(type(LegacyWishGardenBurnSink).runtimeCode)) {
            revert InvalidBurnSink();
        }
    }

    function _withdraw(Bucket bucket, address destination, uint256 amount) private {
        _requireIMD();
        if (
            amount == 0 || destination == address(0) || destination == address(this)
                || destination == burnSink || destination == garden || destination == IMD
        ) revert InvalidWithdrawal();
        IERC20 token = IERC20(IMD);
        uint256 beforeHeld = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(destination);
        token.safeTransfer(destination, amount);
        if (
            token.balanceOf(address(this)) != beforeHeld - amount
                || token.balanceOf(destination) != beforeRecipient + amount
        ) revert InexactTransfer();
        emit BucketWithdrawn(bucket, msg.sender, destination, amount);
    }
}
