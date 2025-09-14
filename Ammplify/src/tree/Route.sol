// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Key, KeyImpl } from "./Key.sol";
import { msb, lsb } from "./BitMath.sol";

uint8 constant MAX_WIDTH_LENGTH = 21; // Given uniswap ticks, 2 raised to this is the maximum width of the tree.

enum Phase {
    NONE,
    PRE_DOWN,
    ROOT_DOWN,
    LEFT_DOWN,
    RIGHT_DOWN,
    PRE_UP,
    ROOT_UP,
    LEFT_UP,
    RIGHT_UP
}

struct Route {
    uint24 rootWidth;
    Key lca; // Lowest Common Ancestor of left and right
    Key left;
    Key right;
}

using RouteImpl for Route global;

library RouteImpl {
    error OutOfBounds(uint24 rootWidth, uint24 left, uint24 right);
    error InvertedRange(uint24 left, uint24 right);

    /* Factory functions */

    /// Create a route from the left and right index, with both being inclusive.
    function make(uint24 _rootWidth, uint24 _left, uint24 _right) internal pure returns (Route memory) {
        if (_right < _left) revert InvertedRange(_left, _right);
        Key leftKey = _makeLeft(_rootWidth, _left);
        Key rightKey = _makeRight(_rootWidth, _right);
        Key lcaKey = _makeLCA(_rootWidth, _left, _right);
        return Route({ rootWidth: _rootWidth, lca: lcaKey, left: leftKey, right: rightKey });
    }

    function _makeLCA(uint24 _rootWidth, uint24 _left, uint24 _right) private pure returns (Key) {
        unchecked {
            if (_left == _right) {
                return KeyImpl.make(_left, 1);
            }
            uint24 diff = _left ^ _right;
            uint24 lcaWidth = msb(diff) << 1;
            require(lcaWidth <= _rootWidth, OutOfBounds(_rootWidth, _left, _right));
            uint24 prefixMask = ~(lcaWidth - 1);
            uint24 lcaBase = prefixMask & _left;
            return KeyImpl.make(lcaBase, lcaWidth);
        }
    }

    /// Creates the inclusive left key for this index.
    function _makeLeft(uint24 _rootWidth, uint24 _left) private pure returns (Key) {
        uint24 width = lsb(_left);
        if (width == 0) return KeyImpl.make(_left, _rootWidth);
        return KeyImpl.make(_left, width);
    }

    /// Creates the inclusive right key for this index.
    function _makeRight(uint24, uint24 _right) private pure returns (Key) {
        uint24 nextBase = _right + 1;
        uint24 width = lsb(nextBase);
        uint24 base = nextBase ^ width;
        return KeyImpl.make(base, width);
    }

    /* Member methods: Walking methods */

    function walk(
        Route memory self,
        function(Key, bool, bytes memory) downFunc,
        function(Key, bool, bytes memory) upFunc,
        function(Phase, bytes memory) phaseFunc,
        bytes memory data
    ) internal {
        walkDown(self, downFunc, phaseFunc, data);
        walkUp(self, upFunc, phaseFunc, data);
    }

    function walkDown(
        Route memory self,
        function(Key, bool, bytes memory) downFunc,
        function(Phase, bytes memory) phaseFunc,
        bytes memory data
    ) internal {
        phaseFunc(Phase.PRE_DOWN, data);
        _walkDownRoot(self, downFunc, data);
        phaseFunc(Phase.ROOT_DOWN, data);
        _walkDownLeft(self, downFunc, data);
        phaseFunc(Phase.LEFT_DOWN, data);
        _walkDownRight(self, downFunc, data);
        phaseFunc(Phase.RIGHT_DOWN, data);
    }

    function walkUp(
        Route memory self,
        function(Key, bool, bytes memory) upFunc,
        function(Phase, bytes memory) phaseFunc,
        bytes memory data
    ) internal {
        phaseFunc(Phase.PRE_UP, data);
        _walkUpLeft(self, upFunc, data);
        phaseFunc(Phase.LEFT_UP, data);
        _walkUpRight(self, upFunc, data);
        phaseFunc(Phase.RIGHT_UP, data);
        _walkUpRoot(self, upFunc, data);
        phaseFunc(Phase.ROOT_UP, data);
    }

    /* Private methods for walking */

    function _walkDownRoot(Route memory self, function(Key, bool, bytes memory) downFunc, bytes memory data) private {
        Key current = KeyImpl.make(0, self.rootWidth);
        while (current.isAbove(self.lca)) {
            downFunc(current, false, data);
            current = current.nextDown(self.lca);
        }
        bool visitLCA = !(self.left.isBelow(self.lca) || self.right.isBelow(self.lca));
        downFunc(self.lca, visitLCA, data);
    }

    function _walkDownLeft(Route memory self, function(Key, bool, bytes memory) downFunc, bytes memory data) private {
        if (!self.left.isBelow(self.lca)) {
            return;
        }
        (Key lcaLeft, Key lcaRight) = self.lca.children();
        // LCA's right is only visited when the right key is unused.
        // We visit it first because up visits it last.
        if (self.right.isAbove(lcaRight)) {
            downFunc(lcaRight, true, data);
        }
        // LCA's left can never be part of our breakdown.
        downFunc(lcaLeft, false, data);
        Key current = lcaLeft;
        uint24 leftBase = self.left.base();

        while (current.isAbove(self.left)) {
            uint24 nextWidth = current.width() >> 1;
            // Check which branch to descend to get to left.
            bool isRight = (leftBase & nextWidth) > 0;
            uint24 currentBase = current.base();
            bool visit = false;
            Key rightKey = KeyImpl.make(currentBase | nextWidth, nextWidth);
            if (isRight) {
                // Left walks traverse right keys.
                current = rightKey;
                // We must visit the last node. This could be optimized.
                visit = current.isEq(self.left);
            } else {
                // When we get to a left key we should visit the right sibling.
                // This is what the walk up does in reverse.
                downFunc(rightKey, true, data);
                current = KeyImpl.make(currentBase, nextWidth);
            }
            downFunc(current, visit, data);
        }
    }

    function _walkDownRight(Route memory self, function(Key, bool, bytes memory) downFunc, bytes memory data) private {
        if (!self.right.isBelow(self.lca)) {
            return;
        }
        (Key lcaLeft, Key lcaRight) = self.lca.children();
        // LCA's left is only visited when the left key is unused.
        // We visit it first since up visits it last.
        if (self.left.isAbove(lcaLeft)) {
            downFunc(lcaLeft, true, data);
        }
        // LCA's right can never be part of our breakdown.
        downFunc(lcaRight, false, data);
        Key current = lcaRight;
        uint24 rightBase = self.right.base();

        while (current.isAbove(self.right)) {
            uint24 nextWidth = current.width() >> 1;
            // Check which branch to descend to get to right.
            bool isRight = (rightBase & nextWidth) > 0;
            uint24 currentBase = current.base();
            bool visit = false;
            Key leftKey = KeyImpl.make(currentBase, nextWidth);
            if (isRight) {
                // When we get to a right key we should visit the left sibling.
                // This visits in the reverse order of a walk up.
                downFunc(leftKey, true, data);
                current = KeyImpl.make(currentBase | nextWidth, nextWidth);
            } else {
                // Right walks traverse left keys.
                current = leftKey;
                // We must visit the last node. This could be optimized.
                visit = current.isEq(self.right);
            }
            downFunc(current, visit, data);
        }
    }

    function _walkUpLeft(Route memory self, function(Key, bool, bytes memory) upFunc, bytes memory data) private {
        if (!self.left.isBelow(self.lca)) {
            return;
        }

        Key current = self.left;
        // We always visit the starting node.
        upFunc(current, true, data);

        (Key lcaLeft, Key lcaRight) = self.lca.children();
        while (lcaLeft.isAbove(current)) {
            bool isRight = (current.width() & current.base()) > 0;
            if (isRight) {
                // We can just walk up without visiting.
                current = current.parent();
                upFunc(current, false, data);
            } else {
                // We have to hop to the right.
                current = current.sibling();
                upFunc(current, true, data);
            }
        }
        // We've propogated to the LCA's left child already.
        // If the right leg is not used, we visit LCA's right child.
        if (self.right.isAbove(lcaRight)) {
            upFunc(lcaRight, true, data);
        }
    }

    function _walkUpRight(Route memory self, function(Key, bool, bytes memory) upFunc, bytes memory data) private {
        if (!self.right.isBelow(self.lca)) {
            return;
        }

        Key current = self.right;
        // We always visit the starting node.
        upFunc(current, true, data);

        (Key lcaLeft, Key lcaRight) = self.lca.children();
        while (lcaRight.isAbove(current)) {
            bool isRight = (current.width() & current.base()) > 0;
            if (isRight) {
                // We have to hop to the left.
                current = current.sibling();
                upFunc(current, true, data);
            } else {
                // We can just walk up without visiting.
                current = current.parent();
                upFunc(current, false, data);
            }
        }
        // We've propogated to the LCA's right child already.
        // If the left leg is not used, we visit LCA's left child.
        if (self.left.isAbove(lcaLeft)) {
            upFunc(lcaLeft, true, data);
        }
    }

    function _walkUpRoot(Route memory self, function(Key, bool, bytes memory) upFunc, bytes memory data) private {
        Key rootKey = KeyImpl.make(0, self.rootWidth);
        Key current = self.lca;
        bool visitLCA = !(self.left.isBelow(self.lca) || self.right.isBelow(self.lca));
        upFunc(current, visitLCA, data);
        while (rootKey.isAbove(current)) {
            current = current.parent();
            upFunc(current, false, data);
        }
    }
}
