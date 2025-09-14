// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { Key, KeyImpl } from "../../src/tree/Key.sol";

contract KeyTest is Test {
    function testMakeExplode() public pure {
        Key k = KeyImpl.make(48, 16);
        (uint24 base, uint24 width) = k.explode();
        assertEq(base, 48);
        assertEq(width, 16);

        assertEq(k.base(), 48);
        assertEq(k.width(), 16);

        assertFalse(k.isEmpty());
        assertFalse(k.isEq(KeyImpl.make(16, 48)));
        assertFalse(k.isEq(KeyImpl.make(48, 4)));
    }

    function testIsEmpty() public pure {
        Key k = Key.wrap(0);
        assertTrue(k.isEmpty());
    }

    function testIsEq() public pure {
        Key k1 = KeyImpl.make(1, 2);
        Key k2 = KeyImpl.make(1, 2);
        assertTrue(k1.isEq(k2));
        assertTrue(k2.isEq(k1));
    }

    function testIsAbove() public pure {
        Key k1 = KeyImpl.make(384, 128);
        Key k2 = KeyImpl.make(384, 64);
        assertTrue(k1.isAbove(k2));
        k2 = KeyImpl.make(384 + 64, 64);
        assertTrue(k1.isAbove(k2));
        k2 = KeyImpl.make(384 - 64, 64);
        assertTrue(k1.isAbove(k2));
        // Same height
        k2 = KeyImpl.make(256, 128);
        assertFalse(k1.isAbove(k2));
        // Below but in sibling subtree
        k2 = KeyImpl.make(256, 64);
        assertTrue(k1.isAbove(k2));
        // Above
        k2 = KeyImpl.make(256, 256);
        assertFalse(k1.isAbove(k2));
    }

    function testIsBelow() public pure {
        Key k1 = KeyImpl.make(36, 4);
        Key k2 = KeyImpl.make(32, 32);
        assertTrue(k1.isBelow(k2));
        k2 = KeyImpl.make(64, 16);
        assertTrue(k1.isBelow(k2));
        k2 = KeyImpl.make(64, 4);
        assertFalse(k1.isBelow(k2));
        k2 = KeyImpl.make(16, 1);
        assertFalse(k1.isBelow(k2));
    }

    function testIsLeaf() public pure {
        Key k1 = KeyImpl.make(32, 1);
        Key k2 = KeyImpl.make(32, 2);
        assertTrue(k1.isLeaf());
        assertFalse(k2.isLeaf());
    }

    function testIsLeft() public pure {
        Key k1 = KeyImpl.make(0, 1);
        Key k2 = KeyImpl.make(1, 1);
        assertTrue(k1.isLeft());
        assertFalse(k2.isLeft());

        k1 = KeyImpl.make(32 + 128, 16);
        assertTrue(k1.isLeft());
        k1 = KeyImpl.make(32, 32);
        assertFalse(k1.isLeft());
    }

    function testIsRight() public pure {
        Key k1 = KeyImpl.make(2, 1);
        Key k2 = KeyImpl.make(1, 1);
        assertFalse(k1.isRight());
        assertTrue(k2.isRight());

        k1 = KeyImpl.make(16, 8);
        k2 = KeyImpl.make(24, 8);
        assertFalse(k1.isRight());
        assertTrue(k2.isRight());
    }

    function testNextDown() public pure {
        // When going down the tree we expect to go down towards the key's base.
        // This is only used by root when we don't have to visit any nodes.
        // Therefore this just follows to get us closer to the base.
        Key k = KeyImpl.make(32, 16);
        Key target = KeyImpl.make(42, 2);

        Key next = k.nextDown(target);
        assertEq(next.base(), 40);
        assertEq(next.width(), 8);

        next = next.nextDown(target);
        assertEq(next.base(), 40);
        assertEq(next.width(), 4);

        next = next.nextDown(target);
        assertEq(next.base(), 42);
        assertEq(next.width(), 2);
    }

    function testParent() public pure {
        Key k = KeyImpl.make(0x5678, 4);
        Key parent = k.parent();
        assertEq(parent.base(), 0x5678);
        assertEq(parent.width(), 8);
        parent = parent.parent();
        assertEq(parent.base(), 0x5670);
        assertEq(parent.width(), 16);
        parent = parent.parent();
        assertEq(parent.base(), 0x5660);
        assertEq(parent.width(), 32);
        parent = parent.parent();
        assertEq(parent.base(), 0x5640);
        assertEq(parent.width(), 64);
        parent = parent.parent();
        assertEq(parent.base(), 0x5600);
        assertEq(parent.width(), 128);
        parent = parent.parent();
        assertEq(parent.base(), 0x5600);
        assertEq(parent.width(), 256);
    }

    function testChildren() public pure {
        Key k = KeyImpl.make(0x5678, 8);
        (Key left, Key right) = k.children();
        assertEq(left.base(), 0x5678);
        assertEq(left.width(), 4);
        assertEq(right.base(), 0x567C);
        assertEq(right.width(), 4);
    }

    function testSibling() public pure {
        Key k1 = KeyImpl.make(0x5678, 4);
        Key k2 = KeyImpl.make(0x567C, 4);
        assertTrue(k1.sibling().isEq(k2));
        assertTrue(k2.sibling().isEq(k1));
    }

    function testLow() public pure {
        Key k = KeyImpl.make(0x1234, 4);
        uint24 low = k.low();
        assertEq(low, 0x1234);
    }

    function testHigh() public pure {
        Key k = KeyImpl.make(0x1234, 4);
        uint24 high = k.high();
        assertEq(high, 0x1234 + 4 - 1);
    }

    function testTicks() public pure {
        Key k = KeyImpl.make(500, 32);
        (int24 low, int24 high) = k.ticks(1024, 5);
        assertEq(low, -60); // (500 - 512) * 5
        assertEq(high, 100); // (532 - 512) * 5
    }
}
