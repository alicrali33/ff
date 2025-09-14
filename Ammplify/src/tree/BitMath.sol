// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

function lsb(uint24 x) pure returns (uint24) {
    unchecked {
        return x & (~x + 1);
    }
}

function msbBit(uint24 x) pure returns (uint8) {
    unchecked {
        // Returns the index of the most significant bit (0-indexed)
        if (x == 0) return 0;

        uint8 i = 0xFF;
        if ((x & 0xFFF000) != 0) {
            x >>= 12;
            i += 12;
        }
        if ((x & 0xFC0) != 0) {
            x >>= 6;
            i += 6;
        }
        if ((x & 0x38) != 0) {
            x >>= 3;
            i += 3;
        }
        if ((x & 0x06) != 0) {
            x >>= 2;
            i += 2;
        }
        if ((x & 0x1) != 0) {
            x >>= 1;
            i += 1;
        }
        return i;
    }
}

function msb(uint24 x) pure returns (uint24) {
    unchecked {
        if (x == 0) return 0;

        return uint24(1) << msbBit(x);
    }
}
