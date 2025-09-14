// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { msb } from "./BitMath.sol";

library TreeTickLib {
    error UnalignedTick(int24 tick, int24 tickSpacing);

    function tickToTreeIndex(int24 tick, uint24 rootWidth, int24 tickSpacing) internal pure returns (uint24) {
        unchecked {
            require(tick % tickSpacing == 0, UnalignedTick(tick, tickSpacing));
            // Convert tick to tree index, adjusting for the root width.
            return uint24(tick / tickSpacing) + rootWidth / 2;
        }
    }

    function treeIndexToTick(uint24 index, uint24 rootWidth, int24 tickSpacing) internal pure returns (int24) {
        unchecked {
            return (int24(index) - int24(rootWidth / 2)) * tickSpacing; // Convert tree index back to tick.
        }
    }

    /// Calculate the largest width of the tree smaller than the total range of the pool.
    function calcRootWidth(int24 minTick, int24 maxTick, int24 tickSpacing) internal pure returns (uint24) {
        // Half the root width must be enough to push the effective minTick to zero.
        uint24 halfRootWidth = msb(uint24((-minTick / tickSpacing)));
        require(int24(halfRootWidth) < maxTick, "Incompatible pool");
        return halfRootWidth * 2;
    }
}
