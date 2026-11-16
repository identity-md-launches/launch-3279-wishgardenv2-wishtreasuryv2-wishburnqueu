// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GardenTestBase} from "../helpers/GardenTestBase.sol";
import {LegacyWishGarden as WishGarden} from "../legacy-src/LegacyWishGarden.sol";
import {GardenEconomy} from "src/GardenEconomy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract IndependentWishGardenBatchFailuresTest is GardenTestBase {
    function setUp() public override {
        super.setUp();
        _confirmCollection();
        _buy(bob, 1, 2);
        _mintNFT(bob, 1000);
        vm.prank(bob);
        garden.claimFreeCandle(1000, 5);
    }

    /// @dev Fault position varies; the retry must receive precisely the IDs the revert released.
    function testFuzz_badMemberRollsBackWholeBatchAndAllowsRepair(
        uint8 lengthSeed,
        uint8 positionSeed,
        uint8 faultSeed
    ) public {
        uint256 count = uint256(lengthSeed) % 49 + 2;
        uint256 position = uint256(positionSeed) % (count - 1) + 1;
        uint8 fault = faultSeed % 5;
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            _mintNFT(alice, i);
            ids[i] = i;
        }
        bytes memory expected;
        if (fault == 0) {
            ids[position] = 0; // repeated inside this batch
            expected = abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, 0);
        } else if (fault == 1) {
            ids[position] = 1000; // consumed in an earlier transaction
            expected = abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, 1000);
        } else if (fault == 2) {
            vm.prank(alice);
            nft.transferFrom(alice, bob, position);
            expected = abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, position);
        } else if (fault == 3) {
            ids[position] = type(uint256).max; // nonexistent, including an arithmetic edge
            expected = abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, type(uint256).max);
        } else {
            vm.mockCallRevert(NFT, abi.encodeCall(IERC721.ownerOf, (position)), hex"12345678");
            expected = abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, position);
        }

        uint256 balanceBefore = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();
        bytes32 firstRecord = keccak256(abi.encode(garden.getCandle(1), garden.getCandle(2)));
        vm.prank(alice);
        vm.expectRevert(expected);
        garden.claimFreeCandles(ids, 6);
        assertEq(garden.totalCandles(), 2);
        assertEq(garden.freeCandles(), 1);
        assertEq(garden.candleCountOf(alice), 0);
        assertEq(garden.candleCountOf(bob), 2);
        assertEq(garden.nftClaimedCandle(1000), 2);
        for (uint256 i; i < count; ++i) {
            assertEq(garden.nftClaimedCandle(i), 0);
        }
        assertEq(keccak256(abi.encode(garden.getCandle(1), garden.getCandle(2))), firstRecord);

        vm.clearMockedCalls();
        if (fault == 2) {
            vm.prank(bob);
            nft.transferFrom(bob, alice, position);
        }
        ids[position] = position;
        vm.prank(alice);
        assertEq(garden.claimFreeCandles(ids, 6), 3);
        for (uint256 i; i < count; ++i) {
            assertEq(garden.nftClaimedCandle(i), 3 + i);
            WishGarden.Candle memory candle = garden.getCandle(3 + i);
            assertEq(candle.nftTokenId, i);
            assertEq(candle.position, 2 + i);
            assertEq(candle.purchaser, alice);
            assertEq(candle.style, 6);
            assertTrue(candle.freeClaim);
        }
        assertEq(garden.candleCountOf(alice), count);
        assertEq(token.balanceOf(alice), balanceBefore);
        assertEq(token.allowance(alice, address(garden)), 0);
        assertEq(token.totalSupply(), supplyBefore);
        _assertAccounting(1);
    }

    function test_setApprovalForAllDoesNotGiveOperatorFreeClaimRights() public {
        _mintNFT(alice, 0);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        uint256[] memory ids = new uint256[](1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WishGarden.NotNFTOwner.selector, 0));
        garden.claimFreeCandles(ids, 0);
        assertEq(garden.nftClaimedCandle(0), 0);
        vm.prank(bob);
        nft.transferFrom(alice, bob, 0);
        vm.prank(bob);
        assertEq(garden.claimFreeCandles(ids, 0), 3);
    }

    function test_consumedTokenCannotBeReusedAfterRoundTripThroughSeveralOwners() public {
        _mintNFT(alice, 0);
        vm.prank(alice);
        garden.claimFreeCandle(0, 0);
        bytes32 record = keccak256(abi.encode(garden.getCandle(3)));
        address[4] memory route = [bob, operations, founder, alice];
        address previous = alice;
        uint256[] memory ids = new uint256[](1);
        for (uint256 i; i < route.length; ++i) {
            vm.prank(previous);
            nft.transferFrom(previous, route[i], 0);
            vm.prank(route[i]);
            vm.expectRevert(abi.encodeWithSelector(WishGarden.NFTAlreadyClaimed.selector, 0));
            garden.claimFreeCandles(ids, uint8(i));
            previous = route[i];
        }
        assertEq(garden.nftClaimedCandle(0), 3);
        assertEq(garden.candleCountOf(alice), 1);
        assertEq(keccak256(abi.encode(garden.getCandle(3))), record);
        assertEq(garden.totalCandles(), 3);
        _assertAccounting(1);
    }

    function test_wrongChainAfterConfirmationFailsBothClaimEntrypoints() public {
        _mintNFT(alice, 0);
        uint256[] memory ids = new uint256[](1);
        vm.chainId(8453);
        (bool enabled, string memory reason) = garden.freeClaimsStatus();
        assertFalse(enabled);
        assertGt(bytes(reason).length, 0);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.WrongChain.selector, 8453));
        garden.claimFreeCandle(0, 0);
        vm.expectRevert(abi.encodeWithSelector(GardenEconomy.WrongChain.selector, 8453));
        garden.claimFreeCandles(ids, 0);
        vm.stopPrank();
        assertEq(garden.nftClaimedCandle(0), 0);
        assertEq(garden.totalCandles(), 2);
    }
}
