// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GardenTestBase} from "../helpers/GardenTestBase.sol";
import {AdversarialIMD} from "../helpers/AdversarialIMD.sol";
import {LegacyWishGarden as WishGarden} from "../legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury as WishGardenTreasury} from "../legacy-src/LegacyWishGardenTreasury.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev Test-only contract wallet. Can own NFTs and hold each treasury permission legitimately.
contract IndependentCallbackWallet is IERC721Receiver {
    address private target;
    bytes private payload;
    bool public attempted;
    bool public succeeded;
    bytes public returned;

    function arm(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
        succeeded = false;
        delete returned;
    }

    function onTokenTransfer() external {
        attempted = true;
        (succeeded, returned) = target.call(payload);
    }

    function execute(address target_, bytes memory data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target_.call(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        attempted = true;
        (succeeded, returned) = target.call(payload);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Fault injection substitutes a callback ERC20; no claim is made that live IMD has hooks.
contract IndependentWishGardenReentrancyTest is GardenTestBase {
    AdversarialIMD private faulty;
    IndependentCallbackWallet private wallet;

    function setUp() public override {
        super.setUp();
        AdversarialIMD implementation = new AdversarialIMD();
        vm.etch(IMD, address(implementation).code);
        faulty = AdversarialIMD(IMD);
        faulty.mint(alice, 1000e18);
        wallet = new IndependentCallbackWallet();
        // All three roles intentionally share a contract wallet, so authorization alone cannot
        // explain why any nested withdrawal is rejected.
        treasury = new WishGardenTreasury(OWNER, address(sink), address(wallet), address(wallet));
        garden = new WishGarden(OWNER, address(treasury));
        vm.prank(OWNER);
        treasury.bindGarden(address(garden));
        _confirmCollection();
        _buy(alice, 10, 0);
        _mintNFT(address(wallet), 0);
        _mintNFT(address(wallet), 1);
        vm.prank(OWNER);
        treasury.transferOwnership(address(wallet));
        wallet.execute(address(treasury), abi.encodeCall(treasury.acceptOwnership, ()));
    }

    function testFuzz_nestedPurchaseOrSingleOrBatchClaimRejectedOnEveryTokenLeg(uint8 entrySeed, bool onPull)
        public
    {
        uint8 entry = entrySeed % 3;
        faulty.mint(address(wallet), 1e18);
        wallet.execute(IMD, abi.encodeCall(IERC20.approve, (address(garden), 1e18)));
        bytes memory data;
        if (entry == 0) {
            data = abi.encodeCall(garden.buyCandles, (1, 1));
        } else if (entry == 1) {
            data = abi.encodeCall(garden.claimFreeCandle, (0, 2));
        } else {
            uint256[] memory ids = new uint256[](2);
            ids[1] = 1;
            data = abi.encodeCall(garden.claimFreeCandles, (ids, 3));
        }
        wallet.arm(address(garden), data);
        faulty.configureCallback(address(wallet), abi.encodeCall(wallet.onTokenTransfer, ()), onPull, !onPull);
        _buy(alice, 1, 4);
        _assertGuard();
        assertEq(garden.totalCandles(), 11);
        assertEq(garden.paidCandles(), 11);
        assertEq(garden.freeCandles(), 0);
        assertEq(garden.nftClaimedCandle(0), 0);
        assertEq(garden.nftClaimedCandle(1), 0);
        assertEq(garden.candleCountOf(address(wallet)), 0);
        assertEq(token.balanceOf(address(wallet)), 1e18);
        assertEq(token.allowance(address(wallet), address(garden)), 1e18);
        _assertAccounting(11);

        // Prove the nested payload is valid outside the active purchase; failure was the guard.
        faulty.configureCallback(address(0), "", false, false);
        bytes memory result = wallet.execute(address(garden), data);
        assertEq(abi.decode(result, (uint256)), 12);
        assertEq(garden.candleCountOf(address(wallet)), entry == 2 ? 2 : 1);
        assertEq(garden.freeCandles(), entry == 0 ? 0 : entry == 1 ? 1 : 2);
        _assertAccounting(entry == 0 ? 12 : 11);
    }

    function testFuzz_authorizedSameAndCrossBucketReentryCannotDoubleWithdraw(
        uint8 outerSeed,
        uint8 nestedSeed
    ) public {
        uint8 outer = outerSeed % 3;
        uint8 nested = nestedSeed % 3;
        bytes memory nestedData = _withdrawData(nested);
        wallet.arm(address(treasury), nestedData);
        faulty.configureCallback(address(wallet), abi.encodeCall(wallet.onTokenTransfer, ()), false, true);
        wallet.execute(address(treasury), _withdrawData(outer));
        _assertGuard();
        assertEq(token.balanceOf(address(wallet)), 1);
        assertEq(treasury.totalEcosystemWithdrawn(), outer == 0 ? 1 : 0);
        assertEq(treasury.totalOperationsClaimed(), outer == 1 ? 1 : 0);
        assertEq(treasury.totalFounderClaimed(), outer == 2 ? 1 : 0);
        _assertAccounting(10);

        faulty.configureCallback(address(0), "", false, false);
        wallet.execute(address(treasury), nestedData);
        assertEq(token.balanceOf(address(wallet)), 2);
        assertEq(treasury.totalEcosystemWithdrawn(), (outer == 0 ? 1 : 0) + (nested == 0 ? 1 : 0));
        assertEq(treasury.totalOperationsClaimed(), (outer == 1 ? 1 : 0) + (nested == 1 ? 1 : 0));
        assertEq(treasury.totalFounderClaimed(), (outer == 2 ? 1 : 0) + (nested == 2 ? 1 : 0));
        _assertAccounting(10);
    }

    function _withdrawData(uint8 bucket) private view returns (bytes memory) {
        if (bucket == 0) return abi.encodeCall(treasury.withdrawEcosystem, (address(wallet), 1));
        if (bucket == 1) return abi.encodeCall(treasury.claimOperations, (1));
        return abi.encodeCall(treasury.claimFounder, (1));
    }

    function _assertGuard() private view {
        assertTrue(wallet.attempted());
        assertFalse(wallet.succeeded());
        assertEq(
            wallet.returned(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }
}

/// @notice These callbacks use the bundled NFT runtime, not a replacement NFT implementation.
contract IndependentWishGardenNFTReceiverTest is GardenTestBase {
    function test_contractReceiverCanClaimUnusedNFTDuringSafeTransfer() public {
        _confirmCollection();
        _mintNFT(alice, 0);
        IndependentCallbackWallet receiver = new IndependentCallbackWallet();
        receiver.arm(address(garden), abi.encodeCall(garden.claimFreeCandle, (0, 6)));
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 0);
        assertTrue(receiver.attempted());
        assertTrue(receiver.succeeded());
        assertEq(abi.decode(receiver.returned(), (uint256)), 1);
        assertEq(nft.ownerOf(0), address(receiver));
        assertEq(garden.getCandle(1).purchaser, address(receiver));
        assertEq(garden.nftClaimedCandle(0), 1);
        _assertAccounting(0);
    }

    function test_safeTransferReceiverCannotReclaimConsumedIDInCallback() public {
        _confirmCollection();
        _mintNFT(alice, 0);
        vm.prank(alice);
        garden.claimFreeCandle(0, 0);
        IndependentCallbackWallet receiver = new IndependentCallbackWallet();
        receiver.arm(address(garden), abi.encodeCall(garden.claimFreeCandle, (0, 6)));
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 0);
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertEq(receiver.returned(), abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, 0));
        assertEq(nft.ownerOf(0), address(receiver));
        assertEq(garden.getCandle(1).purchaser, alice);
        assertEq(garden.candleCountOf(address(receiver)), 0);
        assertEq(garden.totalCandles(), 1);
        _assertAccounting(0);
    }
}
