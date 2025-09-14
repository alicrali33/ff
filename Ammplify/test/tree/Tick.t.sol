// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { TreeTickLib } from "../../src/tree/Tick.sol";
import { Test } from "forge-std/Test.sol";

contract TickTest is Test {
    /// forge-config: default.allow_internal_expect_revert = true
    function testTickToTreeIndex() public {
        uint24 rootWidth = 512;
        int24 tickSpacing = 3;
        uint24 index = TreeTickLib.tickToTreeIndex(3, rootWidth, tickSpacing);
        assertEq(index, 257);
        index = TreeTickLib.tickToTreeIndex(300, rootWidth, tickSpacing);
        assertEq(index, 356);
        vm.expectRevert(abi.encodeWithSelector(TreeTickLib.UnalignedTick.selector, 887, tickSpacing));
        TreeTickLib.tickToTreeIndex(887, rootWidth, tickSpacing);
        index = TreeTickLib.tickToTreeIndex(888, rootWidth, tickSpacing);
        assertEq(index, 552); // 296 + 256
        index = TreeTickLib.tickToTreeIndex(-63, rootWidth, tickSpacing);
        assertEq(index, 235); // -21 + 256
    }
    function testTreeIndexToTick() public pure {
        uint24 rootWidth = 512;
        int24 tickSpacing = 3;
        int24 tick = TreeTickLib.treeIndexToTick(257, rootWidth, tickSpacing);
        assertEq(tick, 3);
        tick = TreeTickLib.treeIndexToTick(356, rootWidth, tickSpacing);
        assertEq(tick, 300);
        tick = TreeTickLib.treeIndexToTick(552, rootWidth, tickSpacing);
        assertEq(tick, 888);
        tick = TreeTickLib.treeIndexToTick(235, rootWidth, tickSpacing);
        assertEq(tick, -63);
    }
}
