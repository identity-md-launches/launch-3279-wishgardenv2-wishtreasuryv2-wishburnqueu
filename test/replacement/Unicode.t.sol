// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {WishText} from "../../src/WishText.sol";

contract TextHarness {
    function validate(string calldata s, bool ack) external pure returns (uint256) {
        return WishText.validate(s, ack);
    }
}

contract UnicodeTest is Test {
    TextHarness h = new TextHarness();

    function test_unicodeScalarBoundariesAndNoNormalization() public view {
        assertEq(h.validate(string(hex"007fc280dfbfe0a080ed9fbfee8080efbfbff0908080f48fbfbf"), true), 10);
        assertEq(h.validate(unicode"é", true), 2);
        assertEq(h.validate(unicode"é", true), 1);
        assertEq(h.validate("", false), 0);
    }

    function test_rejectMalformedOverlongSurrogateTruncatedAndAboveMaximum() public {
        bytes[15] memory invalid = [
            bytes(hex"80"),
            hex"bf",
            hex"c080",
            hex"c1bf",
            hex"c2",
            hex"e08080",
            hex"eda080",
            hex"edbfbf",
            hex"e282",
            hex"f0808080",
            hex"f4908080",
            hex"f5808080",
            hex"ff",
            hex"e228a1",
            hex"f09f8c"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert();
            h.validate(string(invalid[i]), true);
        }
    }

    function test_limitsIndependentBytesAndCodepoints() public {
        assertEq(h.validate(string(new bytes(280)), true), 280);
        vm.expectRevert(WishText.WishTooLong.selector);
        h.validate(string(new bytes(281)), true);
        vm.expectRevert(WishText.WishTooLong.selector);
        h.validate(string(new bytes(1121)), true);
        bytes memory four = new bytes(1120);
        for (uint256 i; i < 280; ++i) {
            four[i * 4] = 0xf4;
            four[i * 4 + 1] = 0x8f;
            four[i * 4 + 2] = 0xbf;
            four[i * 4 + 3] = 0xbf;
        }
        assertEq(h.validate(string(four), true), 280);
    }

    function testFuzz_allValidUnicodeScalars(uint32 seed) public view {
        uint32 c = uint32(bound(seed, 0, 0x10ffff));
        if (c >= 0xd800 && c <= 0xdfff) c = 0x20;
        bytes memory data;
        if (c < 0x80) {
            data = abi.encodePacked(uint8(c));
        } else if (c < 0x800) {
            data = abi.encodePacked(uint8(0xc0 | (c >> 6)), uint8(0x80 | (c & 63)));
        } else if (c < 0x10000) {
            data = abi.encodePacked(
                uint8(0xe0 | (c >> 12)), uint8(0x80 | ((c >> 6) & 63)), uint8(0x80 | (c & 63))
            );
        } else {
            data = abi.encodePacked(
                uint8(0xf0 | (c >> 18)),
                uint8(0x80 | ((c >> 12) & 63)),
                uint8(0x80 | ((c >> 6) & 63)),
                uint8(0x80 | (c & 63))
            );
        }
        assertEq(h.validate(string(data), true), 1);
    }
}
