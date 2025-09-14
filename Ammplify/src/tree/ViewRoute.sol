// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Key, KeyImpl } from "./Key.sol";
import { Phase, Route } from "./Route.sol";

library ViewRouteImpl {
    /* Member methods: Walking methods */

    function walkDown(
        Route memory self,
        function(Key, bool, bytes memory) view downFunc,
        function(Phase, bytes memory) view phaseFunc,
        bytes memory data
    ) internal view {
        phaseFunc(Phase.PRE_DOWN, data);
        _walkDownRoot(self, downFunc, data);
        phaseFunc(Phase.ROOT_DOWN, data);
        _walkDownLeft(self, downFunc, data);
        phaseFunc(Phase.LEFT_DOWN, data);
        _walkDownRight(self, downFunc, data);
        phaseFunc(Phase.RIGHT_DOWN, data);
    }

    /* Private methods for walking */

    function _walkDownRoot(
        Route memory self,
        function(Key, bool, bytes memory) view downFunc,
        bytes memory data
    ) private view {
        Key current = KeyImpl.make(0, self.rootWidth);
        while (current.isAbove(self.lca)) {
            downFunc(current, false, data);
            current = current.nextDown(self.lca);
        }
        bool visitLCA = !(self.left.isBelow(self.lca) || self.right.isBelow(self.lca));
        downFunc(self.lca, visitLCA, data);
    }

    function _walkDownLeft(
        Route memory self,
        function(Key, bool, bytes memory) view downFunc,
        bytes memory data
    ) private view {
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

    function _walkDownRight(
        Route memory self,
        function(Key, bool, bytes memory) view downFunc,
        bytes memory data
    ) private view {
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
}
