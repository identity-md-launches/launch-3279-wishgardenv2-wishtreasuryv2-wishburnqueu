// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GardenTestBase} from "./helpers/GardenTestBase.sol";
import {LegacyWishGarden as WishGarden} from "./legacy-src/LegacyWishGarden.sol";
import {GardenEconomy} from "../src/GardenEconomy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract WishGardenClaimsTest is GardenTestBase {
    function test_freeClaimsDisabledWithExplicitReasonBeforeOwnerConfirmation() public {
        _mintNFT(alice, 0);
        (bool enabled, string memory reason) = garden.freeClaimsStatus();
        assertFalse(enabled);
        assertEq(reason, "Owner has not confirmed the verified official NFT collection");
        vm.prank(alice);
        vm.expectRevert(WishGarden.CollectionNotConfirmed.selector);
        garden.claimFreeCandle(0, 0);
        assertEq(garden.nftClaimedCandle(0), 0);
        assertEq(garden.totalCandles(), 0);
    }

    function test_confirmationRequiresOwnerEvidenceAndVerifiedRuntimeAndIsOnceOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        garden.confirmOfficialCollection(EVIDENCE);
        vm.prank(OWNER);
        vm.expectRevert(WishGarden.MissingVerificationEvidence.selector);
        garden.confirmOfficialCollection(bytes32(0));
        assertEq(NFT.codehash, garden.COLLECTION_CODE_HASH());
        vm.expectEmit(true, true, false, true, address(garden));
        emit WishGarden.OfficialCollectionConfirmed(NFT, OWNER, NFT.codehash, EVIDENCE);
        _confirmCollection();
        assertTrue(garden.collectionConfirmed());
        assertEq(garden.collectionEvidenceHash(), EVIDENCE);
        (bool enabled, string memory reason) = garden.freeClaimsStatus();
        assertTrue(enabled);
        assertEq(bytes(reason).length, 0);
        vm.prank(OWNER);
        vm.expectRevert(WishGarden.CollectionAlreadyConfirmed.selector);
        garden.confirmOfficialCollection(keccak256("replacement"));
    }

    function test_missingOrArbitraryCollectionCodeCannotBeConfirmed() public {
        vm.etch(NFT, "");
        vm.prank(OWNER);
        vm.expectRevert(WishGarden.CollectionVerificationFailed.selector);
        garden.confirmOfficialCollection(EVIDENCE);
        // A contract with any other runtime at that address is also rejected.
        vm.etch(NFT, address(sink).code);
        vm.prank(OWNER);
        vm.expectRevert(WishGarden.CollectionVerificationFailed.selector);
        garden.confirmOfficialCollection(EVIDENCE);
        assertFalse(garden.collectionConfirmed());
    }

    function test_erc165ChecksAndWrongChainRejectConfirmation() public {
        vm.mockCall(
            NFT, abi.encodeCall(IERC165.supportsInterface, (type(IERC721).interfaceId)), abi.encode(false)
        );
        vm.prank(OWNER);
        vm.expectRevert(WishGarden.CollectionVerificationFailed.selector);
        garden.confirmOfficialCollection(EVIDENCE);
        vm.clearMockedCalls();
        vm.mockCall(NFT, abi.encodeCall(IERC165.supportsInterface, (bytes4(0xffffffff))), abi.encode(true));
        vm.prank(OWNER);
        vm.expectRevert(WishGarden.CollectionVerificationFailed.selector);
        garden.confirmOfficialCollection(EVIDENCE);
        vm.clearMockedCalls();
        vm.chainId(8453);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.WrongChain.selector, 8453));
        garden.confirmOfficialCollection(EVIDENCE);
    }

    function test_tokenZeroFreeClaimCollectsAndLocksNoIMD() public {
        _confirmCollection();
        _mintNFT(alice, 0);
        deal(IMD, alice, 0, true);
        uint256 supply = token.totalSupply();
        vm.expectEmit(true, true, true, true, address(garden));
        emit WishGarden.FreeCandleClaimed(alice, 0, 1, NFT);
        vm.prank(alice);
        assertEq(garden.claimFreeCandle(0, 4), 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), supply);
        assertEq(garden.paidCandles(), 0);
        assertEq(garden.freeCandles(), 1);
        assertEq(garden.nftClaimedCandle(0), 1);
        WishGarden.Candle memory candle = garden.getCandle(1);
        assertTrue(candle.freeClaim);
        assertEq(candle.nftTokenId, 0);
        assertEq(candle.purchaser, alice);
        assertEq(candle.style, 4);
        assertEq(candle.position, 0);
        _assertAccounting(0);
    }

    function test_consumedIDRemainsConsumedAfterTransfer() public {
        _confirmCollection();
        _mintNFT(alice, 715);
        vm.startPrank(alice);
        garden.claimFreeCandle(715, 3);
        nft.transferFrom(alice, bob, 715);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, 715));
        garden.claimFreeCandle(715, 1);
        assertEq(garden.nftClaimedCandle(715), 1);
        assertEq(garden.totalCandles(), 1);
        assertEq(garden.getCandle(1).purchaser, alice);
        assertEq(garden.candleCountOf(bob), 0);
    }

    function test_unclaimedIDFollowsCurrentOwnerAndApprovedOperatorCannotClaim() public {
        _confirmCollection();
        _mintNFT(alice, 1999);
        vm.prank(alice);
        nft.approve(bob, 1999);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, 1999));
        garden.claimFreeCandle(1999, 0);
        vm.prank(bob);
        nft.transferFrom(alice, bob, 1999);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, 1999));
        garden.claimFreeCandle(1999, 0);
        vm.prank(bob);
        garden.claimFreeCandle(1999, 0);
        assertEq(garden.getCandle(1).purchaser, bob);
    }

    function test_multipleNFTsPerWalletAndPaidFreeInterleaving() public {
        _confirmCollection();
        for (uint256 id; id < 5; ++id) {
            _mintNFT(alice, id);
        }
        _buy(bob, 1, 0);
        vm.prank(alice);
        garden.claimFreeCandle(0, 1);
        _buy(alice, 1, 2);
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        assertEq(garden.claimFreeCandles(ids, 6), 4);
        assertEq(garden.totalCandles(), 7);
        assertEq(garden.freeCandles(), 5);
        assertEq(garden.paidCandles(), 2);
        assertEq(garden.candleCountOf(alice), 6);
        assertEq(garden.nftClaimedCandle(4), 7);
        assertEq(garden.getCandle(7).nftTokenId, 4);
        _assertAccounting(2);
    }

    function test_duplicateWithinBatchRollsBackEarlierClaims() public {
        _confirmCollection();
        _mintNFT(alice, 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, 1));
        garden.claimFreeCandles(ids, 0);
        assertEq(garden.nftClaimedCandle(1), 0);
        assertEq(garden.totalCandles(), 0);
        assertEq(garden.candleCountOf(alice), 0);
    }

    function test_lateInvalidIDRollsBackWholeBatch() public {
        _confirmCollection();
        _mintNFT(alice, 1);
        _mintNFT(bob, 2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, 2));
        garden.claimFreeCandles(ids, 0);
        assertEq(garden.nftClaimedCandle(1), 0);
        assertEq(garden.totalCandles(), 0);
        assertEq(garden.freeCandles(), 0);
    }

    function test_missingTokenBadStyleAndBatchBounds() public {
        _confirmCollection();
        _mintNFT(alice, 1);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, 2000));
        garden.claimFreeCandle(2000, 0);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.InvalidStyle.selector, 255));
        garden.claimFreeCandle(1, 255);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 0));
        garden.claimFreeCandles(ids, 0);
        ids = new uint256[](51);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.InvalidQuantity.selector, 51));
        garden.claimFreeCandles(ids, 0);
        vm.stopPrank();
        assertEq(garden.totalCandles(), 0);
    }

    function test_runtimeChangeDisablesClaimsWithExplicitReason() public {
        _confirmCollection();
        _mintNFT(alice, 1);
        vm.etch(NFT, address(sink).code);
        (bool enabled, string memory reason) = garden.freeClaimsStatus();
        assertFalse(enabled);
        assertEq(reason, "Official NFT runtime does not match the verified code");
        vm.prank(alice);
        vm.expectRevert(WishGarden.CollectionVerificationFailed.selector);
        garden.claimFreeCandle(1, 0);
        assertEq(garden.nftClaimedCandle(1), 0);
    }

    function test_freeClaimsDoNotDependOnTokenOrTreasuryAvailability() public {
        _confirmCollection();
        _mintNFT(alice, 0);
        vm.etch(IMD, "");
        vm.etch(address(treasury), "");
        vm.prank(alice);
        garden.claimFreeCandle(0, 0);
        assertEq(garden.freeCandles(), 1);
    }

    function test_maximumFreeClaimBatchRemainsGasBounded() public {
        _confirmCollection();
        uint256[] memory ids = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            _mintNFT(alice, i);
            ids[i] = i;
        }
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        garden.claimFreeCandles(ids, 0);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("50 free candles: call gas", used);
        assertLt(used, 8_000_000);
        assertEq(garden.freeCandles(), 50);
        _assertAccounting(0);
    }

    function testFuzz_eachIDCanClaimOnceRegardlessOfTransfers(uint16 idSeed, uint8 styleSeed) public {
        uint256 id = bound(uint256(idSeed), 0, 1999);
        uint8 style = uint8(bound(uint256(styleSeed), 0, 6));
        _confirmCollection();
        _mintNFT(alice, id);
        vm.prank(alice);
        garden.claimFreeCandle(id, style);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, id));
        garden.claimFreeCandle(id, style);
        assertEq(garden.totalCandles(), 1);
        assertEq(garden.freeCandles(), 1);
        _assertAccounting(0);
    }
}
