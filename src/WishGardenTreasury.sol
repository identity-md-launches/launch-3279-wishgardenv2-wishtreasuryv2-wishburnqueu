// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMDBurnQueue} from "./bridge/IMDBurnQueue.sol";
import {IWishGarden} from "./interfaces/IWishGarden.sol";

/// @notice Segregated 30/50/10/10 ledger. Burn funds can leave only through the fixed official OFT route.
contract WishGardenTreasury is IMDBurnQueue {
    using SafeERC20 for IERC20;
    enum Bucket {
        Ecosystem,
        Operations,
        Founder
    }
    address public garden;
    uint256 public ecosystemBalance;
    uint256 public operationsBalance;
    uint256 public founderBalance;
    uint256 public totalPayments;
    uint256 public totalEcosystemWithdrawn;
    uint256 public totalOperationsWithdrawn;
    uint256 public totalFounderWithdrawn;

    error GardenAlreadyBound();
    error InvalidGarden();
    error OnlyGarden();
    error InsufficientFunding();
    error InsufficientBucketBalance();
    error InvalidWithdrawal();
    event GardenBound(address indexed garden);
    event PaymentAllocated(
        address indexed purchaser,
        uint256 indexed firstCandleId,
        uint256 quantity,
        uint256 payment,
        uint256 pendingBurn,
        uint256 ecosystem,
        uint256 operations,
        uint256 founder
    );
    event BucketWithdrawn(
        Bucket indexed bucket, address indexed caller, address indexed destination, uint256 amount
    );

    constructor(address owner_) IMDBurnQueue(owner_) {}

    function bindGarden(address garden_) external onlyOwner nonReentrant {
        _requireEthereum();
        if (garden != address(0)) revert GardenAlreadyBound();
        if (garden_.code.length == 0 || garden_ == address(this)) revert InvalidGarden();
        IWishGarden candidate = IWishGarden(garden_);
        if (candidate.treasury() != address(this) || candidate.owner() != owner() || candidate.IMD() != IMD) {
            revert InvalidGarden();
        }
        garden = garden_;
        emit GardenBound(garden_);
    }

    function recordPayment(address purchaser, uint256 firstCandleId, uint256 quantity) external nonReentrant {
        if (msg.sender != garden || garden == address(0)) revert OnlyGarden();
        if (!purchasesEnabled) revert BridgeNotReady();
        _checkBridge();
        if (purchaser == address(0) || firstCandleId == 0) revert InvalidAddress();
        _checkQuantity(quantity);
        uint256 payment = CANDLE_PRICE * quantity;
        if (IERC20(IMD).balanceOf(address(this)) < accountedBalance() + payment) {
            revert InsufficientFunding();
        }
        uint256 burn = BURN_ALLOCATION_PER_CANDLE * quantity;
        uint256 ecosystem = ECOSYSTEM_PER_CANDLE * quantity;
        uint256 operations = OPERATIONS_PER_CANDLE * quantity;
        uint256 founder = FOUNDER_PER_CANDLE * quantity;
        ecosystemBalance += ecosystem;
        operationsBalance += operations;
        founderBalance += founder;
        totalPayments += payment;
        pendingBurn += burn;
        totalBurnAllocated += burn;
        emit PaymentAllocated(
            purchaser, firstCandleId, quantity, payment, burn, ecosystem, operations, founder
        );
    }

    function withdrawEcosystem(address destination, uint256 amount) external onlyOwner nonReentrant {
        if (amount > ecosystemBalance) revert InsufficientBucketBalance();
        ecosystemBalance -= amount;
        totalEcosystemWithdrawn += amount;
        _withdraw(Bucket.Ecosystem, destination, amount);
    }

    function withdrawOperations(address destination, uint256 amount) external onlyOwner nonReentrant {
        if (amount > operationsBalance) revert InsufficientBucketBalance();
        operationsBalance -= amount;
        totalOperationsWithdrawn += amount;
        _withdraw(Bucket.Operations, destination, amount);
    }

    function withdrawFounder(address destination, uint256 amount) external onlyOwner nonReentrant {
        if (amount > founderBalance) revert InsufficientBucketBalance();
        founderBalance -= amount;
        totalFounderWithdrawn += amount;
        _withdraw(Bucket.Founder, destination, amount);
    }

    function revenueBalance() public view returns (uint256) {
        return ecosystemBalance + operationsBalance + founderBalance;
    }

    function accountedBalance() public view returns (uint256) {
        return pendingBurn + revenueBalance();
    }

    function unallocatedBalance() external view returns (uint256) {
        uint256 held = IERC20(IMD).balanceOf(address(this));
        uint256 accounted = accountedBalance();
        return held > accounted ? held - accounted : 0;
    }

    function _gardenBound() internal view override returns (bool) {
        return garden != address(0);
    }

    function _withdraw(Bucket bucket, address destination, uint256 amount) private {
        _requireIMD();
        if (
            amount == 0 || destination == address(0) || destination == address(this) || destination == garden
                || destination == IMD
        ) revert InvalidWithdrawal();
        IERC20 token = IERC20(IMD);
        uint256 held = token.balanceOf(address(this));
        uint256 recipient = token.balanceOf(destination);
        token.safeTransfer(destination, amount);
        if (
            token.balanceOf(address(this)) != held - amount
                || token.balanceOf(destination) != recipient + amount
        ) {
            revert InexactTransfer();
        }
        emit BucketWithdrawn(bucket, msg.sender, destination, amount);
    }
}
