// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Strict RFC 3629 Unicode scalar validation, without normalization or text alteration.
library WishText {
    uint256 internal constant MAX_BYTES = 1120;
    uint256 internal constant MAX_CODEPOINTS = 280;
    error WishTooLong();
    error InvalidUTF8(uint256 byteOffset);
    error PublicAcknowledgementRequired();

    function validate(string memory text, bool acknowledged) internal pure returns (uint256 count) {
        bytes memory data = bytes(text);
        if (data.length > MAX_BYTES) revert WishTooLong();
        if (data.length != 0 && !acknowledged) revert PublicAcknowledgementRequired();
        uint256 i;
        while (i < data.length) {
            uint8 first = uint8(data[i]);
            uint256 width;
            uint32 scalar;
            if (first <= 0x7f) {
                width = 1;
                scalar = first;
            } else if (first >= 0xc2 && first <= 0xdf) {
                width = 2;
                scalar = first & 0x1f;
            } else if (first >= 0xe0 && first <= 0xef) {
                width = 3;
                scalar = first & 0x0f;
            } else if (first >= 0xf0 && first <= 0xf4) {
                width = 4;
                scalar = first & 0x07;
            } else {
                revert InvalidUTF8(i);
            }
            if (i + width > data.length) revert InvalidUTF8(i);
            for (uint256 j = 1; j < width; ++j) {
                uint8 next = uint8(data[i + j]);
                if (next < 0x80 || next > 0xbf) revert InvalidUTF8(i + j);
                scalar = (scalar << 6) | (next & 0x3f);
            }
            if (
                (width == 2 && scalar < 0x80) || (width == 3 && scalar < 0x800)
                    || (width == 4 && scalar < 0x10000) || (scalar >= 0xd800 && scalar <= 0xdfff)
                    || scalar > 0x10ffff
            ) revert InvalidUTF8(i);
            if (++count > MAX_CODEPOINTS) revert WishTooLong();
            i += width;
        }
    }
}
