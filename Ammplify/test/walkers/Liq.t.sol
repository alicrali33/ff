// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Data, DataImpl } from "../../src/walkers/Data.sol";
import { Key, KeyImpl } from "../../src/tree/Key.sol";
import { Pool, PoolInfo, PoolLib } from "../../src/Pool.sol";
import { UniV3IntegrationSetup } from "../UniV3.u.sol";
import { Asset, AssetLib, AssetNode } from "../../src/Asset.sol";
import { Store } from "../../src/Store.sol";
import { Node } from "../../src/walkers/Node.sol";
import { TreeTickLib } from "../../src/tree/Tick.sol";
import { LiqType, LiqNode, LiqNodeImpl, LiqData, LiqDataLib, LiqWalker } from "../../src/walkers/Liq.sol";
import { FeeLib } from "../../src/Fee.sol";

contract LiqWalkerTest is Test, UniV3IntegrationSetup {
    Node public node;
    Node public left;
    Node public right;

    function setUp() public {
        setUpPool(500); // For a tick spacing of 10.
    }

    function testUp() public {}

    function testCompound() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(16000, 1);
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: 160000,
            highTick: 160010
        });

        // Test without swap fee earnings first.
        Node storage n = data.node(key);
        n.fees.xCFees = 100e18;
        n.fees.yCFees = 200e18;
        n.liq.mLiq = 5e8;
        addPoolLiq(0, 160000, 160010, 5e8);
        LiqWalker.compound(iter, n, data);
        assertGt(n.liq.mLiq, 5e8, "mLiq");
    }

    function testModifyMakerAdd() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(data.fees.rootWidth / 2, 1);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        console.log("ticks", uint24(low), uint24(high));
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        n.liq.mLiq = 200e8;
        n.liq.shares = 100e8;
        AssetNode storage aNode = data.assetNode(key);
        aNode.sliq = 50e8;
        // The sliq should be worth 100e8 so no change happens.
        LiqWalker.modify(iter, n, data, 100e8);
        assertFalse(n.liq.dirty);
        assertEq(aNode.sliq, 50e8, "0");
        assertEq(n.liq.shares, 100e8, "1");
        assertEq(n.liq.mLiq, 200e8, "2");
        assertEq(data.xBalance, 0, "3");
        assertEq(data.yBalance, 0, "4");

        // But now with a higher target we'll add liq.
        LiqWalker.modify(iter, n, data, 200e8);
        assertTrue(n.liq.dirty);
        assertEq(aNode.sliq, 100e8, "5");
        assertEq(n.liq.shares, 150e8, "6");
        assertEq(n.liq.mLiq, 300e8, "7");
        assertGt(data.xBalance, 0, "8");
        // Because our range is entirely above the current price.
        assertEq(data.yBalance, 0, "9");
    }

    function testModifyMakerSubtract() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(data.fees.rootWidth / 2, 1);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        console.log("ticks", uint24(low), uint24(high));
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        AssetNode storage aNode = data.assetNode(key);
        n.liq.mLiq = 200e8;
        n.liq.subtreeMLiq = 1000e8;
        n.fees.xCFees = 500;
        uint128 equivLiq = PoolLib.getEquivalentLiq(low, high, 500, 0, data.sqrtPriceX96, true);
        n.liq.ncLiq = 100e8;
        n.liq.shares = 200e8;
        aNode.sliq = 100e8;
        // The asset owns half the liq here and we want 2/5th of their position left.
        LiqWalker.modify(iter, n, data, ((100e8 + equivLiq) * 2) / 10);
        assertTrue(n.liq.dirty);
        assertApproxEqAbs(aNode.sliq, 40e8, 1, "0");
        assertLt(aNode.sliq, 40e8, "00");
        assertApproxEqAbs(n.liq.shares, 140e8, 1, "1");
        assertLt(n.liq.shares, 140e8, "11");
        assertEq(n.liq.mLiq, 170e8, "2");
        assertLt(data.xBalance, 0, "3");
        assertEq(data.yBalance, 0, "4"); // Since we're above the range.
        assertEq(n.fees.xCFees, 350, "5");
    }

    function testModifyNCMakerAdd() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        // Non-compounding
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, false);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(data.fees.rootWidth / 2, 1);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        console.log("ticks", uint24(low), uint24(high));
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        AssetNode storage aNode = data.assetNode(key);
        n.liq.mLiq = 200e8;
        n.liq.subtreeMLiq = 1000e8;
        n.fees.xCFees = 500;
        n.liq.ncLiq = 100e8;
        n.liq.shares = 100e8;
        aNode.sliq = 50e8;
        LiqWalker.modify(iter, n, data, 80e8);
        assertTrue(n.liq.dirty);
        assertEq(aNode.sliq, 80e8, "0");
        assertEq(n.liq.shares, 100e8, "1");
        assertEq(n.liq.ncLiq, 130e8, "2");
        assertEq(n.liq.mLiq, 230e8, "3");
        assertEq(n.liq.subtreeMLiq, 1030e8, "4");
        assertGt(data.xBalance, 0, "5");
        assertEq(data.yBalance, 0, "6");
    }

    function testModifyNCMakerSubtract() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        // Non-compounding
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, false);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(data.fees.rootWidth / 2, 1);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        console.log("ticks", uint24(low), uint24(high));
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        AssetNode storage aNode = data.assetNode(key);
        n.liq.mLiq = 200e8;
        n.liq.subtreeMLiq = 1000e8;
        n.fees.xCFees = 500;
        n.liq.ncLiq = 100e8;
        n.liq.shares = 100e8;
        aNode.sliq = 50e8;
        LiqWalker.modify(iter, n, data, 25e8);
        assertTrue(n.liq.dirty);
        assertEq(aNode.sliq, 25e8, "0");
        assertEq(n.liq.shares, 100e8, "1");
        assertEq(n.liq.ncLiq, 75e8, "2");
        assertEq(n.liq.mLiq, 175e8, "3");
        assertEq(n.liq.subtreeMLiq, 975e8, "4");
        assertLt(data.xBalance, 0, "5");
        assertEq(data.yBalance, 0, "6");
    }

    function testModifyTakerAdd() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        // Non-compounding
        (Asset storage asset, ) = AssetLib.newTaker(msg.sender, pInfo, -100, 100, 1e24, 0, 0);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(data.fees.rootWidth / 2, 1);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        console.log("ticks", uint24(low), uint24(high));
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        AssetNode storage aNode = data.assetNode(key);
        n.liq.tLiq = 200e8;
        aNode.sliq = 50e8;
        LiqWalker.modify(iter, n, data, 90e8);
        assertTrue(n.liq.dirty);
        assertEq(aNode.sliq, 90e8, "0");
        assertEq(n.liq.tLiq, 240e8, "1");
        assertEq(n.liq.subtreeTLiq, 40e8, "2");
        assertGt(n.liq.subtreeBorrowedX, 0, "3");
        assertGt(n.liq.subtreeBorrowedY, 0, "4");
        assertLt(data.xBalance, 0, "5");
        assertEq(data.yBalance, 0, "6");
    }

    function testModifyTakerSubtract() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        // Non-compounding
        (Asset storage asset, ) = AssetLib.newTaker(msg.sender, pInfo, -100, 100, 1e24, 0, 0);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(data.fees.rootWidth / 2, 1);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        console.log("ticks", uint24(low), uint24(high));
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        AssetNode storage aNode = data.assetNode(key);
        n.liq.tLiq = 200e8;
        aNode.sliq = 50e8;
        n.liq.subtreeTLiq = 1000e8;
        n.liq.subtreeBorrowedX = 500e24;
        n.liq.subtreeBorrowedY = 500e24;
        console.log("modifying to zero");
        LiqWalker.modify(iter, n, data, 0);
        assertTrue(n.liq.dirty);
        assertEq(aNode.sliq, 0, "0");
        assertEq(n.liq.tLiq, 150e8, "1");
        assertEq(n.liq.subtreeTLiq, 950e8, "2");
        assertLt(n.liq.subtreeBorrowedX, 500e24, "3");
        assertLt(n.liq.subtreeBorrowedY, 500e24, "4");
        assertGt(data.xBalance, 0, "5");
        assertEq(data.yBalance, 0, "6");
    }

    function testSolveLiqRepay() public {
        FeeLib.init();
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        // Non-compounding
        (Asset storage asset, ) = AssetLib.newTaker(msg.sender, pInfo, -100, 100, 1e24, 0, 0);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(data.fees.rootWidth / 2, 1);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: 1,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        // Nothing changes if there is no borrow
        n.liq.mLiq = 100e8;
        n.liq.tLiq = 90e8;
        n.liq.lent = 10e8;
        LiqWalker.solveLiq(iter, n, data);
        assertFalse(n.liq.dirty, "0");
        // Nothing changes if the sibling can't repay
        n.liq.borrowed = 20e8;
        n.liq.tLiq = 100e8;
        Node storage sib = data.node(key.sibling());
        sib.liq.mLiq = 50;
        sib.liq.tLiq = 70;
        sib.liq.borrowed = 20;
        LiqWalker.solveLiq(iter, n, data);
        assertFalse(n.liq.dirty, "1");
        assertFalse(sib.liq.dirty, "2");
        // Repays to the parent what it can.
        Node storage parent = data.node(key.parent());
        parent.liq.lent = 100e8;
        sib.liq.tLiq = 0;
        LiqWalker.solveLiq(iter, n, data);
        // But below the compound threshold.
        assertFalse(n.liq.dirty, "3");
        data.liq.compoundThreshold = 10;
        LiqWalker.solveLiq(iter, n, data);
        assertTrue(n.liq.dirty, "4");
        assertTrue(sib.liq.dirty, "5");
        assertTrue(parent.liq.dirty, "6");
        assertEq(parent.liq.preLend, -20, "7");
        assertEq(sib.liq.preBorrow, -20, "8");
        assertEq(sib.liq.net(), 70, "8"); // Won't change until solved.
        assertEq(n.liq.net(), 10e8 - 20, "9");
        LiqWalker.solveLiq(iter, sib, data);
        assertEq(sib.liq.net(), 50, "10");
        LiqWalker.solveLiq(iter, parent, data); // Finalizes the repayment
        assertEq(parent.liq.lent, 100e8 - 20, "11");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testSolveLiqBorrow() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        // Non-compounding
        (Asset storage asset, ) = AssetLib.newTaker(msg.sender, pInfo, -100, 100, 1e24, 0, 0);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Test specific
        Key key = KeyImpl.make(0, data.fees.rootWidth / 2);
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        LiqWalker.LiqIter memory iter = LiqWalker.LiqIter({
            key: key,
            visit: true,
            width: data.fees.rootWidth / 2,
            lowTick: low,
            highTick: high
        });

        Node storage n = data.node(key);
        // We'll want to test that it borrows from the parent even when there is none.
        // And that the sibling gets liquidity even when it doesn't need it.
        n.liq.lent = 10e8;
        data.liq.compoundThreshold = 1e12;
        LiqWalker.solveLiq(iter, n, data);
        Node storage sib = data.node(key.sibling());
        assertEq(n.liq.borrowed, 1e12, "0");
        assertEq(sib.liq.preBorrow, 1e12, "1");
        assertEq(sib.liq.net(), 0, "2"); // Stays 0 until solved.
        assertTrue(n.liq.dirty, "3");
        assertTrue(sib.liq.dirty, "4");
        LiqWalker.solveLiq(iter, sib, data);
        assertEq(sib.liq.borrowed, 1e12, "5");
        assertEq(sib.liq.net(), 1e12, "6"); // Stays 0 until solved.
        // However if the root nets negatively then it errors.
        Key parentKey = key.parent();
        (low, high) = parentKey.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        iter = LiqWalker.LiqIter({
            key: parentKey,
            visit: true,
            width: data.fees.rootWidth,
            lowTick: low,
            highTick: high
        });
        Node storage parent = data.node(parentKey);
        assertEq(parent.liq.net(), 0, "7");
        assertEq(parent.liq.preLend, 1e12, "8");
        assertTrue(parent.liq.dirty, "9");
        vm.expectRevert(abi.encodeWithSelector(LiqWalker.InsufficientBorrowLiquidity.selector, -1e12));
        LiqWalker.solveLiq(iter, parent, data);
    }
}
