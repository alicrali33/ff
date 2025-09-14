// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Data, DataImpl } from "../../src/walkers/Data.sol";
import { Key, KeyImpl } from "../../src/tree/Key.sol";
import { Pool, PoolInfo, PoolLib } from "../../src/Pool.sol";
import { UniV3IntegrationSetup } from "../UniV3.u.sol";
import { Asset, AssetLib } from "../../src/Asset.sol";
import { Store } from "../../src/Store.sol";
import { Node } from "../../src/walkers/Node.sol";
import { TreeTickLib } from "../../src/tree/Tick.sol";
import { Route, RouteImpl, Phase } from "../../src/tree/Route.sol";
import { FeeWalker } from "../../src/walkers/Fee.sol";
import { FeeLib } from "../../src/Fee.sol";
import { WalkerLib } from "../../src/walkers/Lib.sol";

contract FeeWalkerTest is Test, UniV3IntegrationSetup {
    Node public node;
    Node public left;
    Node public right;

    function setUp() public {
        setUpPool(500); // For a tick spacing of 10.
        FeeLib.init();
    }

    function testEmptyWalk() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Route setup.
        Route memory route = RouteImpl.make(25600, 400, 13000);
        // Empty walk.
        route.walk(down, up, phase, WalkerLib.toRaw(data));
    }

    function down(Key key, bool visit, bytes memory raw) internal {
        FeeWalker.down(key, visit, WalkerLib.toData(raw));
    }

    function up(Key key, bool visit, bytes memory raw) internal {
        FeeWalker.up(key, visit, WalkerLib.toData(raw));
    }

    function phase(Phase walkPhase, bytes memory raw) internal pure {
        FeeWalker.phase(walkPhase, WalkerLib.toData(raw));
    }

    /// Tests a single down call
    function testDown() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // First test the case that we are at a leaf, and it converts the unclaims to real fees.
        Key key = KeyImpl.make(10, 1);
        Node storage n = data.node(key);
        n.fees.unclaimedMakerXFees = 100e18;
        n.fees.unpaidTakerYFees = 100e18;
        // With just subtree liqs, and no mliq, only the fee rates are updated.
        n.liq.subtreeMLiq = 100e10;
        n.liq.mLiq = 100e10;
        n.liq.subtreeTLiq = 100e10;
        n.liq.tLiq = 100e10;
        FeeWalker.down(key, false, data);
        assertEq(n.fees.xCFees, 100e18, "1");
        assertEq(n.fees.makerXFeesPerLiqX128, 1e8 << 128, "2");
        assertEq(n.fees.makerYFeesPerLiqX128, 0, "3");
        assertEq(n.fees.takerXFeesPerLiqX128, 0, "4");
        assertEq(n.fees.takerYFeesPerLiqX128, 1e8 << 128, "5");
        // Without more unclaims, nothing changes.
        n.liq.mLiq = 50e10;
        FeeWalker.down(key, false, data);
        assertEq(n.fees.xCFees, 100e18, "6");
        // The rates don't change.
        assertEq(n.fees.makerXFeesPerLiqX128, 1e8 << 128, "7");
        assertEq(n.fees.makerYFeesPerLiqX128, 0, "8");
        assertEq(n.fees.takerXFeesPerLiqX128, 0, "9");
        assertEq(n.fees.takerYFeesPerLiqX128, 1e8 << 128, "10");
        uint256 oldMakerFees = n.fees.makerXFeesPerLiqX128;
        uint256 oldTakerFees = n.fees.takerYFeesPerLiqX128;

        // Now test that in the non-leaf case the same is true, except a portion of the fees given
        // to the children's unclaimeds.
        key = KeyImpl.make(10, 2);
        n = data.node(key);
        (Key leftChild, Key rightChild) = key.children();
        Node storage leftNode = data.node(leftChild);
        Node storage rightNode = data.node(rightChild);
        leftNode.liq.mLiq = 30e10;
        leftNode.liq.subtreeMLiq = 30e10;
        leftNode.liq.tLiq = 10e10;
        leftNode.liq.subtreeTLiq = 10e10;
        leftNode.liq.subtreeBorrowedX = 5e10; // We need borrows cuz we're splitting.
        leftNode.liq.subtreeBorrowedY = 5e10;
        rightNode.liq.subtreeMLiq = 20e10;
        rightNode.liq.mLiq = 20e10;
        rightNode.liq.subtreeTLiq = 20e10;
        rightNode.liq.tLiq = 20e10;
        rightNode.liq.subtreeBorrowedX = 15e10;
        rightNode.liq.subtreeBorrowedY = 12e10;
        // Also add some mliq to ourselves to update the prefix.
        assertEq(data.liq.mLiqPrefix, 0, "11");
        assertEq(data.liq.tLiqPrefix, 0, "12");
        assertEq(n.fees.unclaimedMakerXFees, 0, "13");
        assertEq(n.fees.unpaidTakerYFees, 0, "14");
        n.liq.mLiq = 100e10;
        n.liq.tLiq = 70e10;
        n.liq.subtreeMLiq = 250e10;
        n.liq.subtreeTLiq = 200e10;
        n.fees.unclaimedMakerXFees = 100e18;
        n.fees.unpaidTakerYFees = 100e18;
        FeeWalker.down(key, false, data);
        assertEq(data.liq.mLiqPrefix, 100e10, "15");
        assertEq(data.liq.tLiqPrefix, 70e10, "16");
        // Now that we have subtree fees the unclaims get split with the children.
        assertLt(n.fees.makerXFeesPerLiqX128, oldMakerFees, "17");
        assertEq(n.fees.takerYFeesPerLiqX128 * 2, oldTakerFees, "18");
        assertGt(leftNode.fees.unclaimedMakerXFees, 0, "19");
        assertEq(leftNode.fees.unclaimedMakerYFees, 0, "20");
        assertEq(leftNode.fees.unpaidTakerXFees, 0, "21");
        assertGt(leftNode.fees.unpaidTakerYFees, 0, "22");
        assertGt(rightNode.fees.unclaimedMakerXFees, 0, "23");
        assertEq(rightNode.fees.unclaimedMakerYFees, 0, "24");
        assertEq(rightNode.fees.unpaidTakerXFees, 0, "25");
        assertGt(rightNode.fees.unpaidTakerYFees, 0, "26");

        // Check that the prefix is updated only when not visiting.
        n.fees.unclaimedMakerXFees = 100e18;
        n.fees.unpaidTakerYFees = 100e18;
        FeeWalker.down(key, true, data);
        assertEq(data.liq.mLiqPrefix, 100e10, "27");
        assertEq(data.liq.tLiqPrefix, 70e10, "28");
    }

    function testUp() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);

        // First test a leaf visit.
        Key key = KeyImpl.make(122, 1);
        Node storage n = data.node(key);
        FeeWalker.up(key, true, data);
        // Nothing at all.
        assertEq(n.fees.makerXFeesPerLiqX128, 0, "0");
        assertEq(n.fees.makerYFeesPerLiqX128, 0, "1");
        assertEq(n.fees.takerXFeesPerLiqX128, 0, "2");
        assertEq(n.fees.takerYFeesPerLiqX128, 0, "3");
        assertEq(data.fees.leftColMakerXRateX128, 0, "4");
        assertEq(data.fees.leftColMakerYRateX128, 0, "5");
        assertEq(data.fees.leftColTakerXRateX128, 1, "6");
        assertEq(data.fees.leftColTakerYRateX128, 1, "7");
        assertEq(
            data.fees.rightColMakerXRateX128 +
                data.fees.rightColMakerYRateX128 +
                data.fees.rightColTakerXRateX128 +
                data.fees.rightColTakerYRateX128,
            0,
            "8"
        );

        n.liq.mLiq = 100e18;
        n.liq.subtreeMLiq = 100e18;
        FeeWalker.up(key, true, data);
        // Nothing without borrows.
        assertEq(data.fees.leftColMakerXRateX128 + data.fees.leftColMakerYRateX128, 0, "9");
        assertEq(data.fees.leftColTakerXRateX128, 1, "10");
        assertEq(data.fees.leftColTakerYRateX128, 1, "11");

        // We get charged even without any unclaims.
        n.liq.tLiq = 30e18;
        n.liq.subtreeTLiq = 30e18;
        n.liq.subtreeBorrowedX = 15e18;
        n.liq.subtreeBorrowedY = 25e18;
        FeeWalker.up(key, true, data);
        assertGt(data.fees.leftColMakerXRateX128, 0, "12");
        assertGt(data.fees.leftColMakerYRateX128, 0, "13");
        assertGt(data.fees.leftColTakerXRateX128, 1, "14");
        assertGt(data.fees.leftColTakerYRateX128, 1, "15");
        data.fees.leftColMakerXRateX128 = 0;
        data.fees.leftColMakerYRateX128 = 0;
        data.fees.leftColTakerXRateX128 = 0;
        data.fees.leftColTakerYRateX128 = 0;

        // Test with a non-leaf node and see that the visit also charges to children's unclaimeds.
        key = KeyImpl.make(36, 4);
        n = data.node(key);
        n.liq.mLiq = 100e18;
        n.liq.subtreeMLiq = 2400e18;
        n.liq.tLiq = 3e18;
        n.liq.subtreeTLiq = 300e18;
        n.liq.subtreeBorrowedX = 1500e18;
        n.liq.subtreeBorrowedY = 2500e18;
        (, Key rightChild) = key.children();
        Node storage rightNode = data.node(rightChild);
        rightNode.liq.subtreeTLiq = 240e18;
        rightNode.liq.tLiq = 4e18;
        rightNode.liq.subtreeBorrowedX = 120e18;
        rightNode.liq.subtreeBorrowedY = 240e18;
        // No maker so no maker fees will propogate.
        FeeWalker.up(key, true, data);
        assertEq(rightNode.fees.unclaimedMakerXFees, 0, "16");
        assertEq(rightNode.fees.unclaimedMakerYFees, 0, "17");
        assertGt(rightNode.fees.unpaidTakerXFees, 0, "18");
        assertGt(rightNode.fees.unpaidTakerYFees, 0, "19");
        assertGt(data.fees.rightColMakerXRateX128, 0, "20");
        assertGt(data.fees.rightColMakerYRateX128, 0, "21");
        assertGt(data.fees.rightColTakerXRateX128, 1, "22");
        assertGt(data.fees.rightColTakerYRateX128, 1, "23");
        assertEq(
            data.fees.leftColMakerXRateX128 +
                data.fees.leftColMakerYRateX128 +
                data.fees.leftColTakerXRateX128 +
                data.fees.leftColTakerYRateX128,
            0,
            "24"
        );
        data.fees.rightColMakerXRateX128 = 0;
        data.fees.rightColMakerYRateX128 = 0;
        data.fees.rightColTakerXRateX128 = 0;
        data.fees.rightColTakerYRateX128 = 0;

        // Now test a non-visit without the need to infer rates.
        key = KeyImpl.make(76, 4);
        n = data.node(key);
        // Empty node.
        data.fees.leftColMakerXRateX128 = 10;
        data.fees.leftColMakerYRateX128 = 20;
        data.fees.leftColTakerXRateX128 = 17;
        data.fees.leftColTakerYRateX128 = 21;
        data.fees.rightColMakerXRateX128 = 10;
        data.fees.rightColMakerYRateX128 = 20;
        data.fees.rightColTakerXRateX128 = 13;
        data.fees.rightColTakerYRateX128 = 19;
        FeeWalker.up(key, false, data);
        assertEq(n.fees.xCFees, 0);
        assertEq(n.fees.yCFees, 0);
        assertEq(n.fees.makerXFeesPerLiqX128, 10, "25");
        assertEq(n.fees.makerYFeesPerLiqX128, 20, "26");
        assertEq(n.fees.takerXFeesPerLiqX128, 15, "27");
        assertEq(n.fees.takerYFeesPerLiqX128, 20, "28");
        assertEq(data.fees.rightColMakerXRateX128, 10, "29");
        assertEq(data.fees.rightColMakerYRateX128, 20, "30");
        assertEq(data.fees.rightColTakerXRateX128, 15, "31");
        assertEq(data.fees.rightColTakerYRateX128, 20, "32");
        assertEq(
            data.fees.leftColMakerXRateX128 +
                data.fees.leftColMakerYRateX128 +
                data.fees.leftColTakerXRateX128 +
                data.fees.leftColTakerYRateX128,
            0,
            "33"
        );

        // Non-empty node.
        data.liq.mLiqPrefix = 50e18;
        n.liq.mLiq = 35e18;
        // We have right rates, we'll have to infer from the left child.
        (Key leftChild, ) = key.children();
        Node storage leftNode = data.node(leftChild);
        leftNode.liq.mLiq = 30e18;
        leftNode.liq.subtreeMLiq = 456e18;
        leftNode.liq.tLiq = 7e18;
        leftNode.liq.subtreeTLiq = 120e18;
        leftNode.liq.subtreeBorrowedX = 234e18;
        leftNode.liq.subtreeBorrowedY = 345e18;
        FeeWalker.up(key, false, data);
        assertGt(leftNode.fees.xCFees, 0, "34");
        assertGt(leftNode.fees.yCFees, 0, "35");
        assertGt(leftNode.fees.takerXFeesPerLiqX128, 0, "36");
        assertGt(leftNode.fees.takerYFeesPerLiqX128, 0, "37");
        assertGt(n.fees.xCFees, 0, "38");
        assertGt(n.fees.yCFees, 0, "39");
        assertGt(n.fees.takerXFeesPerLiqX128, 15, "40");
        assertGt(n.fees.makerYFeesPerLiqX128, 20, "41");
        assertEq(data.liq.mLiqPrefix, 15e18);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testLeftRightWeights() public {
        // Just test that left/right weights are computed without issue.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Everything is zero right now. So weights should be equal for both sides.
        (uint256 lw, uint256 rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 8);
        assertEq(lw, rw, "w0");
        // Just adding mliq won't change anything.
        node.liq.mLiq = 100e18;
        (uint256 lw0, uint256 rw0) = FeeWalker.getLeftRightWeights(
            data.liq,
            data.fees,
            node.liq,
            left.liq,
            right.liq,
            8
        );
        assertEq(lw, lw0, "w00");
        assertEq(rw, rw0, "w00");
        // Changing the child weight doesn't do anything since there are no prefixes.
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 128);
        assertEq(lw, rw, "w1");
        // Now with some borrow, but it's still the same.
        node.liq.tLiq = 20e18;
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 8);
        assertEq(lw, rw, "w2");
        // But with higher borrow the weights should go up.
        node.liq.tLiq = 80e18;
        (uint256 lw2, uint256 rw2) = FeeWalker.getLeftRightWeights(
            data.liq,
            data.fees,
            node.liq,
            left.liq,
            right.liq,
            8
        );
        assertGt(lw2, lw, "lw3");
        assertGt(rw2, rw, "rw3");
        assertEq(lw2, rw2, "w3");
        // Add some prefixes of the same ratio, weights should not change.
        data.liq.tLiqPrefix = 800e18;
        data.liq.mLiqPrefix = 1000e18;
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 8);
        assertEq(lw, lw2, "lw4");
        assertEq(rw, rw2, "rw4");
        // And changes in childwidth affect the prefix but proportionally so there is no change.
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 1024);
        assertEq(lw, lw2, "lw5");
        assertEq(rw, rw2, "rw5");
        // But if we change the prefix ratio, then a large child width will affect the weights.
        data.liq.tLiqPrefix = 20e18;
        data.liq.mLiqPrefix = 100e18;
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 1024 * 1024);
        assertLt(lw, lw2, "lw6");
        assertLt(rw, rw2, "rw6");
        assertEq(lw, rw, "w6");

        // With symmetric borrows both weights should stay the same.
        left.liq.subtreeTLiq = 40e18;
        right.liq.subtreeTLiq = 40e18;
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 1024);
        assertEq(lw, rw, "lw7");
        // Max out the ratio using subtrees.
        left.liq.subtreeTLiq = 201e18;
        right.liq.subtreeTLiq = 201e18;
        left.liq.subtreeMLiq = 1e18;
        right.liq.subtreeMLiq = 1e18;
        (lw2, rw2) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 2);
        assertEq(lw2, rw2, "w72");

        // Now test asymmetric borrows.
        left.liq.subtreeTLiq = 90e18;
        right.liq.subtreeTLiq = 10e18;
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 8);
        assertGt(lw, rw, "lw8");
        left.liq.subtreeMLiq = 200e18;
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 8);
        assertLt(lw, rw, "lw9");
        // Upping the child will raise the prefix which will push down the weight discrepancy.
        (lw2, rw2) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 1024);
        assertLt(rw2 - lw2, rw - lw, "lw10");
        // Raising the tLiq prefix will push it back up.
        data.liq.tLiqPrefix = 40e18;
        (lw, rw) = FeeWalker.getLeftRightWeights(data.liq, data.fees, node.liq, left.liq, right.liq, 1024);
        assertGt(rw - lw, rw2 - lw2, "lw11");
    }

    function testChargeTrueFeeRate() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        data.timestamp = uint128(block.timestamp) - 1;

        // First test with leaf nodes to avoid child splits.
        // Test without anything first.
        Key key = KeyImpl.make(32, 8);
        // Since we're using small keys, we'll limit the rootwidth to avoid going under the mintick.
        data.fees.rootWidth = 1 << 12;
        (uint256 cmx, uint256 cmy, uint256 ctx, uint256 cty) = FeeWalker.chargeTrueFeeRate(key, node, data);
        assertEq(cmx, 0, "cmx0");
        assertEq(cmy, 0, "cmy0");
        assertEq(ctx, 1, "ctx0");
        assertEq(cty, 1, "cty0");
        // Test without any takers first to see if their rates get set to 1 and makers stay at 0.
        node.liq.subtreeMLiq = 100e18;
        node.liq.mLiq = 12.5e18;
        (cmx, cmy, ctx, cty) = FeeWalker.chargeTrueFeeRate(key, node, data);
        assertEq(cmx, 0, "cmx1");
        assertEq(cmy, 0, "cmy1");
        assertEq(ctx, 1, "ctx1");
        assertEq(cty, 1, "cty1");
        // Now with some takers.
        key = KeyImpl.make(16, 1); // Leaf from here.
        node.liq.subtreeTLiq = 20e18;
        (cmx, cmy, ctx, cty) = FeeWalker.chargeTrueFeeRate(key, node, data);
        // Because borrows are still 0 the results are still 0/1.
        assertEq(cmx, 0, "cmx2");
        assertEq(cmy, 0, "cmy2");
        assertEq(ctx, 1, "ctx2");
        assertEq(cty, 1, "cty2");
        // Now with some borrows.
        node.liq.subtreeBorrowedX = 2e18;
        node.liq.subtreeBorrowedY = 1e18;
        (cmx, cmy, ctx, cty) = FeeWalker.chargeTrueFeeRate(key, node, data);
        assertGt(ctx, 1, "ctx3");
        assertGt(cty, 1, "cty3");
        assertApproxEqAbs(ctx, cty * 2, 1, "ctxcty3");
        assertEq(ctx / 5, cmx, "cmx3");
        assertEq(cty / 5, cmy, "cmy3");
        assertNotEq(node.fees.xCFees, 0, "xcfees03");
        assertNotEq(node.fees.yCFees, 0, "ycfees03");
        assertEq(node.fees.xCFees, (node.liq.mLiq * cmx) >> 128, "xCFees3");
        assertEq(node.fees.yCFees, (node.liq.mLiq * cmy) >> 128, "yCFees3");
        // If we drop some of the compounding mliq and added ncliq the rates might stay the same
        // but fewer cFees will be given.
        uint256 oldXCFees = node.fees.xCFees;
        uint256 oldYCFees = node.fees.yCFees;
        node.fees.xCFees = 0;
        node.fees.yCFees = 0;
        node.liq.ncLiq = 6.25e18; // Gets subtracted from the overall mliq.
        (uint256 cmx2, uint256 cmy2, uint256 ctx2, uint256 cty2) = FeeWalker.chargeTrueFeeRate(key, node, data);
        assertEq(ctx, ctx2, "ctx4");
        assertEq(cty, cty2, "cty4");
        assertEq(cmx, cmx2, "cmx4");
        assertEq(cmy, cmy2, "cmy4");
        assertEq(node.fees.xCFees, oldXCFees / 2, "xCFees4");
        assertEq(node.fees.yCFees, oldYCFees / 2, "yCFees4");

        // Even without borrows, a prefix tliq will create borrows.
        node.liq.subtreeTLiq = 0;
        node.liq.subtreeBorrowedX = 0;
        node.liq.subtreeBorrowedY = 0;
        data.liq.tLiqPrefix = 50e18;
        (cmx, cmy, ctx, cty) = FeeWalker.chargeTrueFeeRate(key, node, data);
        assertGt(ctx, 1, "ctx5");
        assertGt(cty, 1, "cty5");
        assertGt(cmx, 0, "cmx5");
        assertGt(cmy, 0, "cmy5");

        // Now test with a non-leaf node to make sure child splits are handled.
        key = KeyImpl.make(256, 128);
        node.liq.subtreeMLiq = 200e18;
        node.liq.subtreeBorrowedX = 150e18;
        node.liq.subtreeBorrowedY = 120e18;
        data.liq.mLiqPrefix = 300e18;
        data.liq.tLiqPrefix = 150e18;
        (Key leftKey, Key rightKey) = key.children();
        Node storage leftChild = data.node(leftKey);
        Node storage rightChild = data.node(rightKey);
        leftChild.liq.subtreeMLiq = 12e18;
        leftChild.liq.subtreeTLiq = 6e18;
        leftChild.liq.mLiq = 1e17;
        leftChild.liq.tLiq = 5e16;
        leftChild.liq.subtreeBorrowedX = 4e18;
        leftChild.liq.subtreeBorrowedY = 2e18;
        rightChild.liq.subtreeMLiq = 17e18;
        rightChild.liq.subtreeTLiq = 30e18;
        rightChild.liq.mLiq = 2e17;
        rightChild.liq.tLiq = 1e17;
        rightChild.liq.subtreeBorrowedX = 18e18;
        rightChild.liq.subtreeBorrowedY = 40e18;
        (cmx2, cmy2, ctx2, cty2) = FeeWalker.chargeTrueFeeRate(key, node, data);
        assertGt(ctx2, ctx, "ctx6");
        assertGt(cty2, cty, "cty6");
        assertGt(cmx2, cmx, "cmx6");
        assertGt(cmy2, cmy, "cmy6");
        assertGt(leftChild.fees.unclaimedMakerXFees, 0, "lufx");
        assertGt(leftChild.fees.unclaimedMakerYFees, 0, "lufy");
        assertGt(leftChild.fees.unpaidTakerXFees, 0, "lutx");
        assertGt(leftChild.fees.unpaidTakerYFees, 0, "luty");
        assertGt(rightChild.fees.unclaimedMakerXFees, 0, "rufx");
        assertGt(rightChild.fees.unclaimedMakerYFees, 0, "rufy");
        assertGt(rightChild.fees.unpaidTakerXFees, 0, "rutx");
        assertGt(rightChild.fees.unpaidTakerYFees, 0, "ruty");
    }

    /// Nothing too serious to test here. Just that overall the fees are moved in the right direction.
    /// Can try with different weights and borrow splits.
    function testChildSplit() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);

        // First test that zero/zero works fine.
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertEq(left.fees.unclaimedMakerXFees, 5e18);
        assertEq(right.fees.unclaimedMakerXFees, 5e18);
        assertEq(left.fees.unclaimedMakerYFees, 10e18);
        assertEq(right.fees.unclaimedMakerYFees, 10e18);
        // Technically these should be zero since there can't be taker fees without
        // any borrows but right now the spec might as well do an even split.
        assertEq(left.fees.unpaidTakerXFees, 5e17);
        assertEq(right.fees.unpaidTakerXFees, 5e17);
        assertEq(left.fees.unpaidTakerYFees, 1e18);
        assertEq(right.fees.unpaidTakerYFees, 1e18);
        left.fees.unclaimedMakerXFees = 0;
        left.fees.unclaimedMakerYFees = 0;
        left.fees.unpaidTakerXFees = 0;
        left.fees.unpaidTakerYFees = 0;
        right.fees.unclaimedMakerXFees = 0;
        right.fees.unclaimedMakerYFees = 0;
        right.fees.unpaidTakerXFees = 0;
        right.fees.unpaidTakerYFees = 0;

        // Test only left weights.
        left.liq.subtreeMLiq = 7e18;
        left.liq.subtreeTLiq = 1e18;
        left.liq.subtreeBorrowedX = 1234e18;
        left.liq.subtreeBorrowedY = 5678e18;
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertEq(left.fees.unclaimedMakerXFees, 10e18);
        assertEq(left.fees.unclaimedMakerYFees, 20e18);
        assertEq(left.fees.unpaidTakerXFees, 1e18);
        assertEq(left.fees.unpaidTakerYFees, 2e18);
        assertEq(
            right.fees.unclaimedMakerXFees +
                right.fees.unclaimedMakerYFees +
                right.fees.unpaidTakerXFees +
                right.fees.unpaidTakerYFees,
            0
        );
        left.fees.unclaimedMakerXFees = 0;
        left.fees.unclaimedMakerYFees = 0;
        left.fees.unpaidTakerXFees = 0;
        left.fees.unpaidTakerYFees = 0;
        left.liq.subtreeMLiq = 0;
        left.liq.subtreeTLiq = 0;
        left.liq.subtreeBorrowedX = 0;
        left.liq.subtreeBorrowedY = 0;

        // Right weights.
        right.liq.subtreeMLiq = 100e18;
        right.liq.subtreeTLiq = 10e18;
        right.liq.subtreeBorrowedX = 1234e18;
        right.liq.subtreeBorrowedY = 5678e18;
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertEq(right.fees.unclaimedMakerXFees, 10e18);
        assertEq(right.fees.unclaimedMakerYFees, 20e18);
        assertEq(right.fees.unpaidTakerXFees, 1e18);
        assertEq(right.fees.unpaidTakerYFees, 2e18);
        assertEq(
            left.fees.unclaimedMakerXFees +
                left.fees.unclaimedMakerYFees +
                left.fees.unpaidTakerXFees +
                left.fees.unpaidTakerYFees,
            0
        );
        right.fees.unclaimedMakerXFees = 0;
        right.fees.unclaimedMakerYFees = 0;
        right.fees.unpaidTakerXFees = 0;
        right.fees.unpaidTakerYFees = 0;

        // LeftRightWeights is already tested so we'll just use subtree liqs to adjust that.
        left.liq.subtreeMLiq = 100e18;
        left.liq.subtreeTLiq = 10e18;
        right.liq.subtreeMLiq = 100e18;
        right.liq.subtreeTLiq = 10e18;
        // For now they have the same weights.
        // Equal borrows means equal splits.
        left.liq.subtreeBorrowedX = 10e18;
        left.liq.subtreeBorrowedY = 5e18;
        right.liq.subtreeBorrowedX = 10e18;
        right.liq.subtreeBorrowedY = 5e18;
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertEq(left.fees.unclaimedMakerXFees, right.fees.unclaimedMakerXFees, "mx0");
        assertEq(left.fees.unclaimedMakerYFees, right.fees.unclaimedMakerYFees, "my0");
        assertEq(left.fees.unpaidTakerXFees, right.fees.unpaidTakerXFees, "tx0");
        assertEq(left.fees.unpaidTakerYFees, right.fees.unpaidTakerYFees, "ty0");
        assertEq(left.fees.unclaimedMakerXFees + right.fees.unclaimedMakerXFees, 10e18, "mx00");
        assertEq(left.fees.unclaimedMakerYFees + right.fees.unclaimedMakerYFees, 20e18, "my00");
        assertEq(left.fees.unpaidTakerXFees + right.fees.unpaidTakerXFees, 1e18, "tx00");
        assertEq(left.fees.unpaidTakerYFees + right.fees.unpaidTakerYFees, 2e18, "ty00");
        left.fees.unclaimedMakerXFees = 0;
        left.fees.unclaimedMakerYFees = 0;
        left.fees.unpaidTakerXFees = 0;
        left.fees.unpaidTakerYFees = 0;
        right.fees.unclaimedMakerXFees = 0;
        right.fees.unclaimedMakerYFees = 0;
        right.fees.unpaidTakerXFees = 0;
        right.fees.unpaidTakerYFees = 0;
        // With equal weights but asymmetric borrows, the fee splits will be proportional to the borrows.
        left.liq.subtreeBorrowedX = 30e18;
        left.liq.subtreeBorrowedY = 45e18;
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertApproxEqAbs(left.fees.unclaimedMakerXFees, right.fees.unclaimedMakerXFees * 3, 4, "mx1");
        assertApproxEqAbs(left.fees.unclaimedMakerYFees, right.fees.unclaimedMakerYFees * 9, 10, "my1");
        assertApproxEqAbs(left.fees.unpaidTakerXFees, right.fees.unpaidTakerXFees * 3, 4, "tx1");
        assertApproxEqAbs(left.fees.unpaidTakerYFees, right.fees.unpaidTakerYFees * 9, 10, "ty1");
        assertEq(left.fees.unclaimedMakerXFees + right.fees.unclaimedMakerXFees, 10e18, "mx10");
        assertEq(left.fees.unclaimedMakerYFees + right.fees.unclaimedMakerYFees, 20e18, "my10");
        assertEq(left.fees.unpaidTakerXFees + right.fees.unpaidTakerXFees, 1e18, "tx10");
        assertEq(left.fees.unpaidTakerYFees + right.fees.unpaidTakerYFees, 2e18, "ty10");
        left.fees.unclaimedMakerXFees = 0;
        left.fees.unclaimedMakerYFees = 0;
        left.fees.unpaidTakerXFees = 0;
        left.fees.unpaidTakerYFees = 0;
        right.fees.unclaimedMakerXFees = 0;
        right.fees.unclaimedMakerYFees = 0;
        right.fees.unpaidTakerXFees = 0;
        right.fees.unpaidTakerYFees = 0;
        // With asymmetric weights but equal borrows, the fee splits will skew towards the higher weight.
        left.liq.subtreeBorrowedX = 10e18;
        left.liq.subtreeBorrowedY = 5e18;
        left.liq.subtreeTLiq = 90e18;
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertGt(left.fees.unclaimedMakerXFees, right.fees.unclaimedMakerXFees, "mx2");
        assertGt(left.fees.unclaimedMakerYFees, right.fees.unclaimedMakerYFees, "my2");
        assertGt(left.fees.unpaidTakerXFees, right.fees.unpaidTakerXFees, "tx2");
        assertGt(left.fees.unpaidTakerYFees, right.fees.unpaidTakerYFees, "ty2");
        assertEq(left.fees.unclaimedMakerXFees + right.fees.unclaimedMakerXFees, 10e18, "mx20");
        assertEq(left.fees.unclaimedMakerYFees + right.fees.unclaimedMakerYFees, 20e18, "my20");
        assertEq(left.fees.unpaidTakerXFees + right.fees.unpaidTakerXFees, 1e18, "tx20");
        assertEq(left.fees.unpaidTakerYFees + right.fees.unpaidTakerYFees, 2e18, "ty20");
        left.fees.unclaimedMakerXFees = 0;
        left.fees.unclaimedMakerYFees = 0;
        left.fees.unpaidTakerXFees = 0;
        left.fees.unpaidTakerYFees = 0;
        right.fees.unclaimedMakerXFees = 0;
        right.fees.unclaimedMakerYFees = 0;
        right.fees.unpaidTakerXFees = 0;
        right.fees.unpaidTakerYFees = 0;
        left.liq.subtreeTLiq = 10e18; // Back to the original.

        // And check the asymmetry works for the right as well.
        right.liq.subtreeBorrowedX = 100e18;
        right.liq.subtreeBorrowedY = 20e18;
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertApproxEqAbs(right.fees.unclaimedMakerXFees, left.fees.unclaimedMakerXFees * 10, 11, "mx3");
        assertApproxEqAbs(right.fees.unclaimedMakerYFees, left.fees.unclaimedMakerYFees * 4, 5, "my3");
        assertApproxEqAbs(right.fees.unpaidTakerXFees, left.fees.unpaidTakerXFees * 10, 11, "tx3");
        assertApproxEqAbs(right.fees.unpaidTakerYFees, left.fees.unpaidTakerYFees * 4, 5, "ty3");
        assertEq(left.fees.unclaimedMakerXFees + right.fees.unclaimedMakerXFees, 10e18, "mx30");
        assertEq(left.fees.unclaimedMakerYFees + right.fees.unclaimedMakerYFees, 20e18, "my30");
        assertEq(left.fees.unpaidTakerXFees + right.fees.unpaidTakerXFees, 1e18, "tx30");
        assertEq(left.fees.unpaidTakerYFees + right.fees.unpaidTakerYFees, 2e18, "ty30");
        left.fees.unclaimedMakerXFees = 0;
        left.fees.unclaimedMakerYFees = 0;
        left.fees.unpaidTakerXFees = 0;
        left.fees.unpaidTakerYFees = 0;
        right.fees.unclaimedMakerXFees = 0;
        right.fees.unclaimedMakerYFees = 0;
        right.fees.unpaidTakerXFees = 0;
        right.fees.unpaidTakerYFees = 0;
        right.liq.subtreeBorrowedX = 10e18;
        right.liq.subtreeBorrowedY = 5e18;
        // With asymmetric weight
        right.liq.subtreeMLiq = 33e18;
        FeeWalker.childSplit(data, node, left, right, 8, 1e18, 2e18, 10e18, 20e18);
        assertGt(right.fees.unclaimedMakerXFees, left.fees.unclaimedMakerXFees, "mx4");
        assertGt(right.fees.unclaimedMakerYFees, left.fees.unclaimedMakerYFees, "my4");
        assertGt(right.fees.unpaidTakerXFees, left.fees.unpaidTakerXFees, "tx4");
        assertGt(right.fees.unpaidTakerYFees, left.fees.unpaidTakerYFees, "ty4");
        assertEq(left.fees.unclaimedMakerXFees + right.fees.unclaimedMakerXFees, 10e18, "mx40");
        assertEq(left.fees.unclaimedMakerYFees + right.fees.unclaimedMakerYFees, 20e18, "my40");
        assertEq(left.fees.unpaidTakerXFees + right.fees.unpaidTakerXFees, 1e18, "tx40");
        assertEq(left.fees.unpaidTakerYFees + right.fees.unpaidTakerYFees, 2e18, "ty40");
        left.fees.unclaimedMakerXFees = 0;
        left.fees.unclaimedMakerYFees = 0;
        left.fees.unpaidTakerXFees = 0;
        left.fees.unpaidTakerYFees = 0;
        right.fees.unclaimedMakerXFees = 0;
        right.fees.unclaimedMakerYFees = 0;
        right.fees.unpaidTakerXFees = 0;
        right.fees.unpaidTakerYFees = 0;
        right.liq.subtreeMLiq = 100e18; // Back to the original.
    }

    function testAdd128Fees() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        assertEq(110, FeeWalker.add128Fees(50, 60, data, true));
        assertEq(120, FeeWalker.add128Fees(50, 70, data, false));
        assertEq(type(uint128).max, FeeWalker.add128Fees(1 << 127, 1 << 127, data, true));
        assertEq(data.xBalance, -1, "dx1");
        assertEq(type(uint128).max, FeeWalker.add128Fees(1 << 127, 1 << 128, data, false));
        assertEq(data.yBalance, -(1 << 127) - 1, "dy1");
    }
}
