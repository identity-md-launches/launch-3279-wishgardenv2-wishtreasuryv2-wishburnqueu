// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReplacementTestBase} from "./ReplacementTestBase.sol";
import {LegacyWishRegistry} from "../../src/LegacyWishRegistry.sol";
import {LegacyWishGarden} from "../legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury} from "../legacy-src/LegacyWishGardenTreasury.sol";
import {LegacyWishGardenBurnSink} from "../legacy-src/LegacyWishGardenBurnSink.sol";
import {IdentityNFTRuntime} from "../fixtures/IdentityNFTRuntime.sol";
import {WishText} from "../../src/WishText.sol";

interface ILegacyNFT {
    function mint(uint256 id) external;
    function transferFrom(address, address, uint256) external;
}

contract LegacyRegistryTest is ReplacementTestBase {
    LegacyWishGarden internal legacy;
    LegacyWishGardenTreasury internal oldTreasury;
    LegacyWishGardenBurnSink internal oldSink;
    ILegacyNFT internal nft;

    function setUp() public override {
        super.setUp();
        address nftAddress = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
        vm.etch(nftAddress, IdentityNFTRuntime.code());
        nft = ILegacyNFT(nftAddress);
        oldSink = new LegacyWishGardenBurnSink();
        LegacyWishGardenTreasury templateTreasury =
            new LegacyWishGardenTreasury(OWNER, address(oldSink), OWNER, OWNER);
        vm.etch(registry.LEGACY_TREASURY(), address(templateTreasury).code);
        oldTreasury = LegacyWishGardenTreasury(registry.LEGACY_TREASURY());
        vm.store(address(oldTreasury), bytes32(0), bytes32(uint256(uint160(OWNER))));
        LegacyWishGarden template = new LegacyWishGarden(OWNER, address(oldTreasury));
        vm.etch(registry.LEGACY_GARDEN(), address(template).code);
        legacy = LegacyWishGarden(registry.LEGACY_GARDEN());
        vm.store(address(legacy), bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.startPrank(OWNER);
        oldTreasury.bindGarden(address(legacy));
        legacy.confirmOfficialCollection(EVIDENCE);
        vm.stopPrank();
        vm.prank(alice);
        nft.mint(7);
    }

    function test_freeClaimThenFailedWishRetryWithoutRepurchaseOrLegacyMutation() public {
        vm.prank(alice);
        uint256 id = legacy.claimFreeCandle(7, 2);
        bytes32 record = keccak256(abi.encode(legacy.getCandle(id)));
        vm.prank(alice);
        vm.expectRevert();
        registry.registerWish(id, string(bytes(hex"c080")), true);
        (address author,) = registry.wishOf(id);
        assertEq(author, address(0));
        vm.record();
        vm.prank(alice);
        registry.registerWish(id, unicode"One wish 🌱", true);
        (, bytes32[] memory writes) = vm.accesses(address(legacy));
        assertEq(writes.length, 0);
        (author,) = registry.wishOf(id);
        assertEq(author, alice);
        assertEq(keccak256(abi.encode(legacy.getCandle(id))), record);
        assertEq(legacy.totalCandles(), 1);
        assertEq(garden.totalCandles(), 0);
        assertEq(treasury.totalPayments(), 0);
        vm.prank(alice);
        vm.expectRevert(LegacyWishRegistry.WishAlreadyRegistered.selector);
        registry.registerWish(id, "edit", true);
    }

    function test_transferDoesNotChangeLegacyAuthorOrLifetimeClaim() public {
        vm.prank(alice);
        uint256 id = legacy.claimFreeCandle(7, 2);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 7);
        vm.prank(bob);
        vm.expectRevert(LegacyWishRegistry.NotLegacyPurchaser.selector);
        registry.registerWish(id, "stolen", true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LegacyWishGarden.NFTAlreadyClaimed.selector, 7));
        legacy.claimFreeCandle(7, 2);
        vm.prank(alice);
        registry.registerWish(id, "original purchaser", true);
        assertEq(legacy.nftClaimedCandle(7), id);
    }

    function test_paidLegacyCandlesAndFundsStayVisibleAsLocked() public {
        vm.startPrank(alice);
        token.approve(address(legacy), 10e18);
        uint256 id = legacy.buyCandles(10, 0);
        vm.stopPrank();
        vm.prank(alice);
        registry.registerWish(id, "legacy paid", true);
        (
            address sink,
            uint256 held,
            uint256 locked,
            uint256 payments,
            uint256 allocated,
            uint256 ecosystem,
            uint256 operations,
            uint256 founder
        ) = registry.legacyFunds();
        assertEq(sink, address(oldSink));
        assertEq(held, 7e18);
        assertEq(locked, 3e18);
        assertEq(payments, 10e18);
        assertEq(allocated, 3e18);
        assertEq(ecosystem, 5e18);
        assertEq(operations, 1e18);
        assertEq(founder, 1e18);
        vm.prank(alice);
        token.transfer(address(legacy), 1e18);
        assertEq(registry.legacyGardenBalance(), 1e18);
        assertEq(registry.legacyCandle(id).purchaser, alice);
        assertEq(oldTreasury.totalSupplyBurned(), 0);
        uint256 newId = _buy(1, 0, "new");
        assertTrue(newId != id);
        assertTrue(garden.candleKey(newId) != registry.candleKey(id));
        assertEq(legacy.totalCandles(), 10);
        assertEq(token.balanceOf(address(oldSink)), 3e18);
    }

    function test_uncreatedEmptyUnacknowledgedWrongChainAndAdminCannotRegister() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.registerWish(1, "before candle", true);
        vm.prank(alice);
        uint256 id = legacy.claimFreeCandle(7, 0);
        vm.prank(alice);
        vm.expectRevert(LegacyWishRegistry.EmptyWish.selector);
        registry.registerWish(id, "", true);
        vm.prank(alice);
        vm.expectRevert(WishText.PublicAcknowledgementRequired.selector);
        registry.registerWish(id, "public", false);
        vm.prank(OWNER);
        vm.expectRevert(LegacyWishRegistry.NotLegacyPurchaser.selector);
        registry.registerWish(id, "admin", true);
        vm.chainId(8453);
        vm.prank(alice);
        vm.expectRevert();
        registry.registerWish(id, "wrong chain", true);
    }

    function test_reproducedOriginalMissingWishAndFormerOwnerRetainsOperations() public {
        vm.startPrank(alice);
        token.approve(address(legacy), 1e18);
        legacy.buyCandles(1, 0);
        vm.stopPrank();
        vm.prank(alice);
        (bool ok,) = address(legacy)
            .call(
                abi.encodeWithSignature("buyCandlesWithWish(uint256,uint8,string,bool)", 1, 0, "absent", true)
            );
        assertFalse(ok);
        vm.prank(OWNER);
        oldTreasury.transferOwnership(bob);
        vm.prank(bob);
        oldTreasury.acceptOwnership();
        vm.prank(bob);
        vm.expectRevert(LegacyWishGardenTreasury.UnauthorizedBeneficiary.selector);
        oldTreasury.claimOperations(0.1e18);
        vm.prank(OWNER);
        oldTreasury.claimOperations(0.1e18);
        assertEq(oldTreasury.operationsBalance(), 0);
    }

    function test_reproducedOriginalSecondLedgerFindingThenReplacementRejects() public {
        vm.prank(alice);
        legacy.claimFreeCandle(7, 0);
        LegacyWishGarden secondLegacy = new LegacyWishGarden(OWNER, address(oldTreasury));
        vm.prank(OWNER);
        secondLegacy.confirmOfficialCollection(EVIDENCE);
        vm.prank(alice);
        uint256 duplicate = secondLegacy.claimFreeCandle(7, 0);
        assertEq(duplicate, 1); // reproduced imported defect
        assertEq(secondLegacy.getCandle(duplicate).position, legacy.getCandle(1).position);
        assertEq(secondLegacy.freeCandles(), 1);
        vm.prank(alice);
        (bool ok,) = address(garden).call(abi.encodeWithSignature("claimFreeCandle(uint256,uint8)", 7, 0));
        assertFalse(ok);
        assertEq(garden.totalCandles(), 0);
    }
}
