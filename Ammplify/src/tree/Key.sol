// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { TreeTickLib } from "./Tick.sol";

type Key is uint48;

using KeyImpl for Key global;

library KeyImpl {
    /// @dev use 48 bits for casting convenience. Args will only occupy 24 bits.
    function make(uint48 _base, uint48 _width) internal pure returns (Key) {
        return Key.wrap((_width << 24) | _base);
    }

    function _rawBase(Key key) private pure returns (uint48) {
        return Key.unwrap(key) & 0x00FFFFFF;
    }

    function _rawWidth(Key key) private pure returns (uint48) {
        return Key.unwrap(key) >> 24;
    }

    function base(Key key) internal pure returns (uint24) {
        return uint24(_rawBase(key));
    }

    function width(Key key) internal pure returns (uint24) {
        return uint24(_rawWidth(key));
    }

    function explode(Key self) internal pure returns (uint24 _base, uint24 _width) {
        uint48 keyValue = Key.unwrap(self);
        _base = uint24(keyValue & 0x00FFFFFF);
        _width = uint24(keyValue >> 24);
    }

    function isEmpty(Key self) internal pure returns (bool) {
        return Key.unwrap(self) == 0;
    }

    function isEq(Key self, Key other) internal pure returns (bool) {
        return Key.unwrap(self) == Key.unwrap(other);
    }

    function isAbove(Key self, Key other) internal pure returns (bool) {
        return _rawWidth(self) > _rawWidth(other);
    }

    function isBelow(Key self, Key other) internal pure returns (bool) {
        return _rawWidth(self) < _rawWidth(other);
    }

    function isLeaf(Key self) internal pure returns (bool) {
        return _rawWidth(self) == 1;
    }

    function isLeft(Key self) internal pure returns (bool) {
        return (_rawBase(self) & _rawWidth(self)) == 0;
    }

    function isRight(Key self) internal pure returns (bool) {
        return (_rawBase(self) & _rawWidth(self)) != 0;
    }

    /// Get the next child key to traverse when going down the tree.
    function nextDown(Key self, Key other) internal pure returns (Key) {
        uint48 nextWidth = _rawWidth(self) >> 1;
        uint48 rawBase = _rawBase(self);
        uint48 otherBase = _rawBase(other);
        uint48 nextBase = (nextWidth & otherBase > 0) ? rawBase | nextWidth : rawBase;
        return make(nextBase, nextWidth);
    }

    function parent(Key self) internal pure returns (Key) {
        uint48 rawBase = _rawBase(self);
        uint48 rawWidth = _rawWidth(self);
        return make(~rawWidth & rawBase, rawWidth << 1);
    }

    function children(Key self) internal pure returns (Key left, Key right) {
        uint48 rawBase = _rawBase(self);
        uint48 childWidth = _rawWidth(self) >> 1;
        left = make(rawBase, childWidth);
        right = make(rawBase | childWidth, childWidth);
        return (left, right);
    }

    function sibling(Key self) internal pure returns (Key) {
        uint48 rawBase = _rawBase(self);
        uint48 rawWidth = _rawWidth(self);
        return make(rawBase ^ rawWidth, rawWidth);
    }

    function low(Key self) internal pure returns (uint24) {
        return uint24(_rawBase(self));
    }

    /// @dev Tree high indices are inclusive
    function high(Key self) internal pure returns (uint24) {
        return uint24(_rawBase(self) + _rawWidth(self) - 1);
    }

    /// @dev highTick here should be exclusive.
    function ticks(
        Key self,
        uint24 rootWidth,
        int24 tickSpacing
    ) internal pure returns (int24 lowTick, int24 highTick) {
        uint24 lowIdx = uint24(_rawBase(self));
        uint24 highIdx = uint24(lowIdx + _rawWidth(self)); // Exclusive
        lowTick = TreeTickLib.treeIndexToTick(lowIdx, rootWidth, tickSpacing);
        highTick = TreeTickLib.treeIndexToTick(highIdx, rootWidth, tickSpacing);
    }
}
