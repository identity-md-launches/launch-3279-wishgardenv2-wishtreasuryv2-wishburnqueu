// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReplacementTestBase} from "../replacement/ReplacementTestBase.sol";
import {WalletGas} from "../helpers/WalletGas.sol";
import {WishText} from "src/WishText.sol";
import {WishGarden} from "src/WishGarden.sol";
import {LegacyWishRegistry} from "src/LegacyWishRegistry.sol";
import {LegacyWishGarden} from "../legacy-src/LegacyWishGarden.sol";
import {LegacyWishGardenTreasury} from "../legacy-src/LegacyWishGardenTreasury.sol";
import {LegacyWishGardenBurnSink} from "../legacy-src/LegacyWishGardenBurnSink.sol";
import {IdentityNFTRuntime} from "../fixtures/IdentityNFTRuntime.sol";

contract ReviewUnicodeHarness {
    function validate(bytes calldata input) external pure returns (uint256) {
        return WishText.validate(string(input), true);
    }
}

contract UnicodeRangeOracleTest is Test {
    ReviewUnicodeHarness internal harness = new ReviewUnicodeHarness();

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_arbitraryByteStringsAgreeWithIndependentRangeOracle(bytes memory input) public view {
        _compare(input);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_shortByteStringsExerciseAllWidths(bytes4 word, uint8 lengthSeed) public view {
        bytes memory input = abi.encodePacked(word);
        uint256 length = uint256(lengthSeed) % 4 + 1;
        assembly ("memory-safe") { mstore(input, length) }
        _compare(input);
    }

    function test_allLeadingBytesAndContinuationClasses() public view {
        for (uint256 b; b < 256; ++b) {
            _compare(abi.encodePacked(uint8(b)));
            _compare(abi.encodePacked(uint8(b), uint8(0x80)));
            _compare(abi.encodePacked(uint8(0xe0), uint8(b), uint8(0x80)));
            _compare(abi.encodePacked(uint8(0xed), uint8(b), uint8(0x80)));
            _compare(abi.encodePacked(uint8(0xf0), uint8(b), uint8(0x80), uint8(0x80)));
            _compare(abi.encodePacked(uint8(0xf4), uint8(b), uint8(0x80), uint8(0x80)));
        }
    }

    function _compare(bytes memory input) private view {
        (bool expected, uint256 count) = _reference(input);
        (bool ok, bytes memory result) =
            address(harness).staticcall(abi.encodeCall(harness.validate, (input)));
        assertEq(ok, expected, "UTF-8 acceptance differs from byte-range oracle");
        if (ok) assertEq(abi.decode(result, (uint256)), count);
    }

    /// @dev RFC 3629 byte-range table. Deliberately does not reconstruct scalars like production does.
    function _reference(bytes memory input) private pure returns (bool, uint256 count) {
        if (input.length > 1120) return (false, 0);
        uint256 i;
        while (i < input.length) {
            uint8 lead = uint8(input[i]);
            uint256 width;
            uint8 secondMin = 0x80;
            uint8 secondMax = 0xbf;
            if (lead < 0x80) {
                width = 1;
            } else if (lead >= 0xc2 && lead <= 0xdf) {
                width = 2;
            } else if (lead >= 0xe0 && lead <= 0xef) {
                width = 3;
                if (lead == 0xe0) secondMin = 0xa0;
                if (lead == 0xed) secondMax = 0x9f;
            } else if (lead >= 0xf0 && lead <= 0xf4) {
                width = 4;
                if (lead == 0xf0) secondMin = 0x90;
                if (lead == 0xf4) secondMax = 0x8f;
            } else {
                return (false, count);
            }
            if (i + width > input.length) return (false, count);
            if (width > 1 && (uint8(input[i + 1]) < secondMin || uint8(input[i + 1]) > secondMax)) {
                return (false, count);
            }
            for (uint256 j = 2; j < width; ++j) {
                if (uint8(input[i + j]) < 0x80 || uint8(input[i + j]) > 0xbf) return (false, count);
            }
            if (++count > 280) return (false, count);
            i += width;
        }
        return (true, count);
    }
}

contract WishUnicodeIntegrationReviewTest is ReplacementTestBase {
    function testFuzz_multibyteWishesRemainByteExactForEveryCandle(
        uint32 scalarSeed,
        uint16 countSeed,
        uint8 q
    ) public {
        uint32 scalar = scalarSeed % 0x110000;
        if (scalar >= 0xd800 && scalar <= 0xdfff) scalar += 0x800;
        bytes memory unit = _encodeScalar(scalar);
        uint256 count = bound(countSeed, 1, 280);
        bytes memory text = new bytes(count * unit.length);
        for (uint256 i; i < text.length; ++i) {
            text[i] = unit[i % unit.length];
        }
        uint256 quantity = bound(q, 1, 50);
        uint256 first = _buy(quantity, 6, string(text));
        for (uint256 i; i < quantity; ++i) {
            (address author, string memory stored) = garden.wishOf(first + i);
            assertEq(author, alice);
            assertEq(bytes(stored), text, "stored UTF-8 must not be normalized, truncated or escaped");
        }
        _assertAccounting(quantity);
    }

    function testFuzz_invalidUTF8AfterValidPrefixReportsOffsetAndLeavesNoPurchase(
        uint8 prefixSeed,
        uint8 kindSeed
    ) public {
        _buy(1, 0, "prior");
        uint256 prefixLength = uint256(prefixSeed); // at most 255; leaves room before the codepoint cap
        bytes memory prefix = new bytes(prefixLength);
        for (uint256 i; i < prefixLength; ++i) {
            prefix[i] = 0x61;
        }
        bytes[8] memory invalid = [
            bytes(hex"80"),
            hex"c080",
            hex"eda080",
            hex"f4908080",
            hex"e282",
            hex"e228a1",
            hex"f09f0080",
            hex"f09f8c00"
        ];
        uint256 kind = kindSeed % invalid.length;
        uint256 offset = prefixLength + (kind == 5 ? 1 : kind == 6 ? 2 : kind == 7 ? 3 : 0);
        vm.prank(alice);
        token.approve(address(garden), 1e18);
        uint256 balance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WishText.InvalidUTF8.selector, offset));
        garden.buyCandlesWithWish(1, 0, string(bytes.concat(prefix, invalid[kind])), true);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.allowance(alice, address(garden)), 1e18);
        assertEq(garden.wishBatch(PREFIX + 2), 0);
        _assertAccounting(1);
        vm.prank(alice);
        uint256 id = garden.buyCandlesWithWish(1, 0, unicode"retry 🌱", true);
        assertEq(id, PREFIX + 2);
        _assertAccounting(2);
    }

    function test_byteLimitCodepointLimitAndAcknowledgementAreAtomicAtPurchaseBoundary() public {
        vm.prank(alice);
        token.approve(address(garden), 50e18);
        bytes memory maximum = new bytes(1120);
        for (uint256 i; i < 280; ++i) {
            maximum[i * 4] = 0xf4;
            maximum[i * 4 + 1] = 0x8f;
            maximum[i * 4 + 2] = 0xbf;
            maximum[i * 4 + 3] = 0xbf;
        }
        vm.startPrank(alice);
        vm.expectRevert(WishText.PublicAcknowledgementRequired.selector);
        garden.buyCandlesWithWish(50, 0, string(maximum), false);
        vm.expectRevert(WishText.WishTooLong.selector);
        garden.buyCandlesWithWish(50, 0, string(bytes.concat(maximum, hex"00")), true);
        vm.expectRevert(WishText.WishTooLong.selector);
        garden.buyCandlesWithWish(50, 0, string(new bytes(281)), true);
        vm.stopPrank();
        _assertAccounting(0);
        assertEq(token.allowance(alice, address(garden)), 50e18);
        _buy(50, 0, string(maximum));
        _assertAccounting(50);
    }

    function _encodeScalar(uint32 c) private pure returns (bytes memory) {
        if (c <= 0x7f) return abi.encodePacked(uint8(c));
        if (c <= 0x7ff) return abi.encodePacked(uint8(0xc0 | (c >> 6)), uint8(0x80 | (c & 63)));
        if (c <= 0xffff) {
            return
                abi.encodePacked(
                    uint8(0xe0 | (c >> 12)), uint8(0x80 | ((c >> 6) & 63)), uint8(0x80 | (c & 63))
                );
        }
        return abi.encodePacked(
            uint8(0xf0 | (c >> 18)),
            uint8(0x80 | ((c >> 12) & 63)),
            uint8(0x80 | ((c >> 6) & 63)),
            uint8(0x80 | (c & 63))
        );
    }
}

interface IReviewLegacyNFT {
    function mint(uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

contract LegacyWishBindingReviewTest is ReplacementTestBase, WalletGas {
    LegacyWishGarden internal legacy;
    LegacyWishGardenTreasury internal oldTreasury;
    LegacyWishGardenBurnSink internal oldSink;
    IReviewLegacyNFT internal nft;

    function setUp() public override {
        super.setUp();
        address collection = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
        vm.etch(collection, IdentityNFTRuntime.code());
        nft = IReviewLegacyNFT(collection);
        oldSink = new LegacyWishGardenBurnSink();
        LegacyWishGardenTreasury treasuryTemplate =
            new LegacyWishGardenTreasury(OWNER, address(oldSink), OWNER, OWNER);
        vm.etch(registry.LEGACY_TREASURY(), address(treasuryTemplate).code);
        oldTreasury = LegacyWishGardenTreasury(registry.LEGACY_TREASURY());
        vm.store(address(oldTreasury), bytes32(0), bytes32(uint256(uint160(OWNER))));
        LegacyWishGarden gardenTemplate = new LegacyWishGarden(OWNER, address(oldTreasury));
        vm.etch(registry.LEGACY_GARDEN(), address(gardenTemplate).code);
        legacy = LegacyWishGarden(registry.LEGACY_GARDEN());
        vm.store(address(legacy), bytes32(0), bytes32(uint256(uint160(OWNER))));
        vm.startPrank(OWNER);
        oldTreasury.bindGarden(address(legacy));
        legacy.confirmOfficialCollection(EVIDENCE);
        vm.stopPrank();
        vm.prank(alice);
        nft.mint(7);
    }

    function testFuzz_repeatedNFTTransfersNeverResetClaimOrReassignWish(uint8 hopsSeed, uint8 styleSeed)
        public
    {
        vm.prank(alice);
        uint256 id = legacy.claimFreeCandle(7, styleSeed % 7);
        bytes32 candleHash = keccak256(abi.encode(legacy.getCandle(id)));
        address holder = alice;
        uint256 hops = uint256(hopsSeed) % 6 + 1;
        for (uint256 i; i < hops; ++i) {
            address next = makeAddr(string.concat("review NFT holder ", vm.toString(i)));
            vm.prank(holder);
            nft.transferFrom(holder, next, 7);
            vm.prank(next);
            vm.expectRevert(abi.encodeWithSelector(LegacyWishGarden.NFTAlreadyClaimed.selector, 7));
            legacy.claimFreeCandle(7, 0);
            vm.prank(next);
            vm.expectRevert(LegacyWishRegistry.NotLegacyPurchaser.selector);
            registry.registerWish(id, "new holder cannot take authorship", true);
            holder = next;
        }
        vm.prank(alice);
        vm.expectRevert(WishText.PublicAcknowledgementRequired.selector);
        registry.registerWish(id, "public forever", false);
        (address missing,) = registry.wishOf(id);
        assertEq(missing, address(0));
        vm.record();
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(registry));
        emit LegacyWishRegistry.LegacyWishPublished(address(legacy), id, alice, unicode"permanent 🌱");
        registry.registerWish(id, unicode"permanent 🌱", true);
        _assertNoWrites(address(legacy));
        _assertNoWrites(address(oldTreasury));
        _assertNoWrites(address(oldSink));
        _assertNoWrites(address(nft));
        vm.prank(alice);
        vm.expectRevert(LegacyWishRegistry.WishAlreadyRegistered.selector);
        registry.registerWish(id, "overwrite", true);
        vm.prank(OWNER);
        vm.expectRevert(LegacyWishRegistry.WishAlreadyRegistered.selector);
        registry.registerWish(id, "admin overwrite", true);
        assertEq(keccak256(abi.encode(legacy.getCandle(id))), candleHash);
        assertEq(legacy.nftClaimedCandle(7), id);
        (address author, string memory text) = registry.wishOf(id);
        assertEq(author, alice);
        assertEq(text, unicode"permanent 🌱");
        _assertAccounting(0);
    }

    function test_replacementIDsCannotBeUsedToClaimLegacyAuthorship() public {
        vm.startPrank(alice);
        uint256 legacyId = legacy.claimFreeCandle(7, 0);
        vm.stopPrank();
        uint256 newId = _buy(1, 0, "new paid wish");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LegacyWishGarden.CandleNotFound.selector, newId));
        registry.registerWish(newId, "wrong namespace", true);
        (address author,) = registry.wishOf(newId);
        assertEq(author, address(0));
        vm.expectRevert(abi.encodeWithSelector(WishGarden.CandleNotFound.selector, legacyId));
        garden.wishOf(legacyId);
        assertTrue(registry.candleKey(legacyId) != garden.candleKey(newId));
        assertEq(legacy.nftClaimedCandle(7), legacyId);
    }

    function test_registryAtWalletGasWithMaximumTextAndExistingWish() public {
        vm.startPrank(alice);
        uint256 freeId = legacy.claimFreeCandle(7, 0);
        token.approve(address(legacy), 1e18);
        uint256 paidId = legacy.buyCandles(1, 0);
        registry.registerWish(freeId, "already published", true);
        vm.stopPrank();
        bytes memory text = new bytes(1120);
        for (uint256 i; i < 280; ++i) {
            text[i * 4] = 0xf0;
            text[i * 4 + 1] = 0x9f;
            text[i * 4 + 2] = 0x8c;
            text[i * 4 + 3] = 0xb1;
        }
        assertSameAtWalletGas(
            alice, address(registry), abi.encodeCall(registry.registerWish, (paidId, string(text), true))
        );
        (address author,) = registry.wishOf(paidId);
        assertEq(author, address(0), "wallet-gas helper must restore state");
    }

    function _assertNoWrites(address target) private {
        (, bytes32[] memory writes) = vm.accesses(target);
        assertEq(writes.length, 0, "registry must never mutate legacy state");
    }
}
