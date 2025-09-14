// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { lsb, msbBit, msb } from "../../src/tree/BitMath.sol";

contract BitMathTest is Test {
    function testLsb() public pure {
        assertEq(lsb(0), 0);
        assertEq(lsb(1), 1);
        assertEq(lsb(2), 2);
        assertEq(lsb(3), 1);
        assertEq(lsb(8), 8);
        assertEq(lsb(10), 2);
        assertEq(lsb((1 << 14) + (1 << 21) + (1 << 18)), 1 << 14);
    }

    function testMsbBit() public pure {
        assertEq(msbBit(0), 0);
        assertEq(msbBit(1), 0);
        assertEq(msbBit(2), 1);
        assertEq(msbBit(8), 3);
        assertEq(msbBit(10), 3);
        assertEq(msbBit((1 << 14) + (1 << 21) + (1 << 18)), 21);
    }

    function testMsb() public pure {
        assertEq(msb(0), 0);
        assertEq(msb(1), 1);
        assertEq(msb(2), 2);
        assertEq(msb(8), 8);
    }
}
