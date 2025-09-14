// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { SmoothRateCurveConfig, SmoothRateCurveLib } from "Commons/Math/SmoothRateCurveLib.sol";
import { Key } from "../tree/Key.sol";
import { Phase } from "../tree/Route.sol";
import { Data } from "./Data.sol";
import { Node } from "./Node.sol";
import { LiqNode, LiqData } from "./Liq.sol";
import { FullMath } from "../FullMath.sol";
import { FeeLib } from "../Fee.sol";
import { PoolInfo } from "../Pool.sol";

/// Data we need to persist for fee accounting.
/// @dev ONLY operations in FeeWalker are modifying this data.
/// Others can read though so they should be aware of their ordering.
struct FeeNode {
    uint256 takerXFeesPerLiqX128;
    uint256 takerYFeesPerLiqX128;
    uint256 makerXFeesPerLiqX128; // Used for non-compounding makers
    uint256 makerYFeesPerLiqX128; // Used for non-compounding makers
    // Note that these are uint128. They hold a fee balance which can grow unbounded.
    // However assuming 18 decimals, and a price of one trillion, earning 1 million a day, it would take
    // a year of not compounding to cause an overflow. We do have an escape hatch for fees just in case.
    uint128 xCFees; // Fees collected in x for compounding liquidity.
    uint128 yCFees; // Fees collected in y for compounding liquidity.
    uint128 unclaimedMakerXFees; // Unclaimed fees in x.
    uint128 unclaimedMakerYFees; // Unclaimed fees in y.
    uint128 unpaidTakerXFees; // Unpaid fees in x.
    uint128 unpaidTakerYFees; // Unpaid fees in y.
}

/// Transient data for calculating fees during a walk.
struct FeeData {
    uint24 rootWidth; // The width of the root node.
    int24 tickSpacing; // The tick spacing for the pool.
    // Fee curve info.
    SmoothRateCurveConfig rateConfig; // The rate curve for calculating the true taker fee rate.
    SmoothRateCurveConfig splitConfig; // For splitting fees across subtrees when approximating unclaimed fees.
    // Fee charge propogation.
    // @dev These ALREADY have the time diff multiplied in to avoid re-multiplying.
    // These report the per liq fee rate paid by each "column" of the tree,
    // for which you can just average for your own column rate.
    uint256 leftColMakerXRateX128;
    uint256 leftColTakerXRateX128;
    uint256 leftColMakerYRateX128;
    uint256 leftColTakerYRateX128;
    uint256 rightColMakerXRateX128;
    uint256 rightColTakerXRateX128;
    uint256 rightColMakerYRateX128;
    uint256 rightColTakerYRateX128;
    // Root switch entries
    uint256 lcaLeftColMakerXRateX128;
    uint256 lcaLeftColTakerXRateX128;
    uint256 lcaLeftColMakerYRateX128;
    uint256 lcaLeftColTakerYRateX128;
    // We don't need a right rate since that can be copied from the above right rates.
}

library FeeDataLib {
    function make(PoolInfo memory pInfo) internal view returns (FeeData memory data) {
        return
            FeeData({
                rootWidth: pInfo.treeWidth,
                tickSpacing: pInfo.tickSpacing,
                rateConfig: FeeLib.getRateCurve(pInfo.poolAddr),
                splitConfig: FeeLib.getSplitCurve(pInfo.poolAddr),
                // Unused till propogation.
                leftColMakerXRateX128: 0,
                leftColTakerXRateX128: 0,
                leftColMakerYRateX128: 0,
                leftColTakerYRateX128: 0,
                rightColMakerXRateX128: 0,
                rightColTakerXRateX128: 0,
                rightColMakerYRateX128: 0,
                rightColTakerYRateX128: 0,
                lcaLeftColMakerXRateX128: 0,
                lcaLeftColTakerXRateX128: 0,
                lcaLeftColMakerYRateX128: 0,
                lcaLeftColTakerYRateX128: 0
            });
    }
}

library FeeWalker {
    using SmoothRateCurveLib for SmoothRateCurveConfig;

    function down(Key key, bool visit, Data memory data) internal {
        // On the way down, we accumulate the prefixes and claim fees.
        Node storage node = data.node(key);

        // We just claim all of our unclaimed.
        if (key.isLeaf()) {
            // If we're at a leaf, we can claim fees.
            // We round up to overpay dust.
            if (node.liq.subtreeTLiq > 0) {
                // If the tLiq is zero we would never propogate any fees down anyways.
                node.fees.takerXFeesPerLiqX128 += FullMath.mulDivRoundingUp(
                    node.fees.unpaidTakerXFees,
                    1 << 128,
                    node.liq.subtreeTLiq
                );
                node.fees.takerYFeesPerLiqX128 += FullMath.mulDivRoundingUp(
                    node.fees.unpaidTakerYFees,
                    1 << 128,
                    node.liq.subtreeTLiq
                );
                node.fees.unpaidTakerXFees = 0;
                node.fees.unpaidTakerYFees = 0;
            }

            if (node.liq.mLiq > 0) {
                // If there is no mliq, fees wouldn't propogate down.
                (uint128 c, uint256 nonCX128) = node.liq.splitMakerFees(node.fees.unclaimedMakerXFees);
                node.fees.makerXFeesPerLiqX128 += nonCX128;
                node.fees.xCFees += c;
                node.fees.unclaimedMakerXFees = 0;

                (c, nonCX128) = node.liq.splitMakerFees(node.fees.unclaimedMakerYFees);
                node.fees.makerYFeesPerLiqX128 += nonCX128;
                node.fees.yCFees += c;
                node.fees.unclaimedMakerYFees = 0;
            }

            return;
        }

        // We claim our own fees first.
        {
            uint24 width = key.width();
            uint256 myLiq;
            // Takers
            if (node.liq.tLiq > 0) {
                myLiq = node.liq.tLiq * width;
                uint256 perTLiqX128 = FullMath.mulDivRoundingUp(
                    node.fees.unpaidTakerXFees,
                    1 << 128,
                    node.liq.subtreeTLiq
                );
                node.fees.takerXFeesPerLiqX128 += perTLiqX128;
                if (myLiq == node.liq.subtreeTLiq) {
                    // If we're the entire subtree, we can just zero it out.
                    node.fees.unpaidTakerXFees = 0;
                } else {
                    // Otherwise we round up to avoid underpaying dust.
                    node.fees.unpaidTakerXFees -= uint128(FullMath.mulX128(perTLiqX128, myLiq, true));
                }
                perTLiqX128 = FullMath.mulDivRoundingUp(node.fees.unpaidTakerYFees, 1 << 128, node.liq.subtreeTLiq);
                node.fees.takerYFeesPerLiqX128 += perTLiqX128;
                if (myLiq == node.liq.subtreeTLiq) {
                    node.fees.unpaidTakerYFees = 0;
                } else {
                    node.fees.unpaidTakerYFees -= uint128(FullMath.mulX128(perTLiqX128, myLiq, true));
                }
            }
            // Makers
            if (node.liq.mLiq > 0) {
                myLiq = node.liq.mLiq * width;
                uint256 myEarnings = FullMath.mulDiv(node.fees.unclaimedMakerXFees, myLiq, node.liq.subtreeMLiq);
                node.fees.unclaimedMakerXFees -= uint128(myEarnings);
                (uint128 c, uint256 nonCX128) = node.liq.splitMakerFees(myEarnings);
                node.fees.makerXFeesPerLiqX128 += nonCX128;
                node.fees.xCFees += c;
                myEarnings = FullMath.mulDiv(node.fees.unclaimedMakerYFees, myLiq, node.liq.subtreeMLiq);
                node.fees.unclaimedMakerYFees -= uint128(myEarnings);
                (c, nonCX128) = node.liq.splitMakerFees(myEarnings);
                node.fees.makerYFeesPerLiqX128 += nonCX128;
                node.fees.yCFees += c;
            }
        }

        // Now split fees before updating prefixes.
        (Key leftChild, Key rightChild) = key.children();
        Node storage leftNode = data.node(leftChild);
        Node storage rightNode = data.node(rightChild);
        uint24 childWidth = leftChild.width();
        childSplit(
            data,
            node,
            leftNode,
            rightNode,
            childWidth,
            node.fees.unpaidTakerXFees,
            node.fees.unpaidTakerYFees,
            node.fees.unclaimedMakerXFees,
            node.fees.unclaimedMakerYFees
        );
        node.fees.unpaidTakerXFees = 0;
        node.fees.unpaidTakerYFees = 0;
        node.fees.unclaimedMakerXFees = 0;
        node.fees.unclaimedMakerYFees = 0;

        // Now we can add to the prefix if we're not visiting.
        if (!visit) {
            data.liq.mLiqPrefix += node.liq.mLiq;
            data.liq.tLiqPrefix += node.liq.tLiq;
        }
    }

    function up(Key key, bool visit, Data memory data) internal {
        Node storage node = data.node(key);
        // On the way up, we charge the true fee rate as much as possible.
        if (visit) {
            // We use the real fee rate calculation since we can.
            // The prefix will be correct going into this because the prop beforehand has removed their prefix.
            if (key.isLeft()) {
                (
                    data.fees.leftColMakerXRateX128,
                    data.fees.leftColMakerYRateX128,
                    data.fees.leftColTakerXRateX128,
                    data.fees.leftColTakerYRateX128
                ) = chargeTrueFeeRate(key, node, data);
            } else {
                (
                    data.fees.rightColMakerXRateX128,
                    data.fees.rightColMakerYRateX128,
                    data.fees.rightColTakerXRateX128,
                    data.fees.rightColTakerYRateX128
                ) = chargeTrueFeeRate(key, node, data);
            }
        } else {
            // Check for any uncalculated fee rates using the Taker rate.
            (Key leftKey, Key rightKey) = key.children();
            if (data.fees.leftColTakerXRateX128 == 0) {
                // The prefix is correct here since we haven't removed ourselves yet.
                (
                    data.fees.leftColMakerXRateX128,
                    data.fees.leftColMakerYRateX128,
                    data.fees.leftColTakerXRateX128,
                    data.fees.leftColTakerYRateX128
                ) = chargeTrueFeeRate(leftKey, data.node(leftKey), data);
            }
            if (data.fees.rightColTakerXRateX128 == 0) {
                (
                    data.fees.rightColMakerXRateX128,
                    data.fees.rightColMakerYRateX128,
                    data.fees.rightColTakerXRateX128,
                    data.fees.rightColTakerYRateX128
                ) = chargeTrueFeeRate(rightKey, data.node(rightKey), data);
            }

            // We just infer our rate from the children.
            uint256 colMakerXRateX128 = (data.fees.leftColMakerXRateX128 + data.fees.rightColMakerXRateX128) / 2;
            uint256 colMakerYRateX128 = (data.fees.leftColMakerYRateX128 + data.fees.rightColMakerYRateX128) / 2;
            // +1 to round up.
            uint256 colTakerXRateX128 = (data.fees.leftColTakerXRateX128 + data.fees.rightColTakerXRateX128 + 1) / 2;
            uint256 colTakerYRateX128 = (data.fees.leftColTakerYRateX128 + data.fees.rightColTakerYRateX128 + 1) / 2;

            // We charge/pay our own fees.
            node.fees.takerXFeesPerLiqX128 += colTakerXRateX128;
            node.fees.takerYFeesPerLiqX128 += colTakerYRateX128;
            node.fees.makerXFeesPerLiqX128 += colMakerXRateX128;
            node.fees.makerYFeesPerLiqX128 += colMakerYRateX128;
            // We round down to avoid overpaying dust.
            uint256 compoundingLiq = node.liq.mLiq - node.liq.ncLiq;
            node.fees.xCFees = add128Fees(
                node.fees.xCFees,
                FullMath.mulX128(colMakerXRateX128, compoundingLiq, false),
                data,
                true
            );
            node.fees.yCFees = add128Fees(
                node.fees.yCFees,
                FullMath.mulX128(colMakerYRateX128, compoundingLiq, false),
                data,
                false
            );

            // The children have already been charged their fees.

            // We propogate up our fees.
            if (key.isLeft()) {
                data.fees.leftColMakerXRateX128 = colMakerXRateX128;
                data.fees.leftColMakerYRateX128 = colMakerYRateX128;
                data.fees.leftColTakerXRateX128 = colTakerXRateX128;
                data.fees.leftColTakerYRateX128 = colTakerYRateX128;
                data.fees.rightColMakerXRateX128 = 0;
                data.fees.rightColMakerYRateX128 = 0;
                data.fees.rightColTakerXRateX128 = 0;
                data.fees.rightColTakerYRateX128 = 0;
            } else {
                data.fees.rightColMakerXRateX128 = colMakerXRateX128;
                data.fees.rightColMakerYRateX128 = colMakerYRateX128;
                data.fees.rightColTakerXRateX128 = colTakerXRateX128;
                data.fees.rightColTakerYRateX128 = colTakerYRateX128;
                data.fees.leftColMakerXRateX128 = 0;
                data.fees.leftColMakerYRateX128 = 0;
                data.fees.leftColTakerXRateX128 = 0;
                data.fees.leftColTakerYRateX128 = 0;
            }

            // We remove the prefix now, before we potentially visit the sibling.
            data.liq.mLiqPrefix -= node.liq.mLiq;
            data.liq.tLiqPrefix -= node.liq.tLiq;
        }
    }

    function phase(Phase walkPhase, Data memory data) internal pure {
        if (walkPhase == Phase.LEFT_UP) {
            // At the end of left, if we visited the lca right child then
            // we can just proceed to the root propogation with the same child rates.
            if (data.fees.rightColTakerXRateX128 == 0) {
                // We're going to visit the right route, so we need to save the left.
                data.fees.lcaLeftColMakerXRateX128 = data.fees.leftColMakerXRateX128;
                data.fees.lcaLeftColMakerYRateX128 = data.fees.leftColMakerYRateX128;
                data.fees.lcaLeftColTakerXRateX128 = data.fees.leftColTakerXRateX128;
                data.fees.lcaLeftColTakerYRateX128 = data.fees.leftColTakerYRateX128;
            }
        } else if (walkPhase == Phase.RIGHT_UP) {
            // At the end of right, we'll proceed to root propogation but if we have a
            // saved lca left child rate, then we need to move that back into use.
            if (data.fees.lcaLeftColTakerXRateX128 != 0) {
                data.fees.leftColMakerXRateX128 = data.fees.lcaLeftColMakerXRateX128;
                data.fees.leftColMakerYRateX128 = data.fees.lcaLeftColMakerYRateX128;
                data.fees.leftColTakerXRateX128 = data.fees.lcaLeftColTakerXRateX128;
                data.fees.leftColTakerYRateX128 = data.fees.lcaLeftColTakerYRateX128;
            }
        }
    }

    /* Helpers */

    /// Returns the initial split weights for the left and right children according to liquidity utilization.
    /// @dev Be sure to multiply the by weights by the quantity of the borrowed asset to get the actual
    /// split weights.
    /// @dev This assumes the prefix does not include the current node's liquidity.
    function getLeftRightWeights(
        LiqData memory liqData,
        FeeData memory feeData,
        LiqNode storage node,
        LiqNode storage left,
        LiqNode storage right,
        uint24 childWidth
    ) internal view returns (uint256 leftWeight, uint256 rightWeight) {
        uint256 myMLiq = node.mLiq * childWidth;
        uint256 myTLiq = node.tLiq * childWidth;
        {
            uint256 leftMLiq = left.subtreeMLiq + myMLiq;
            uint256 totalMLiq = leftMLiq + liqData.mLiqPrefix * childWidth;
            if (totalMLiq == 0) {
                leftWeight = feeData.splitConfig.calculateRateX64(0);
            } else {
                uint256 leftTLiq = left.subtreeTLiq + myTLiq;
                uint256 totalTLiq = leftTLiq + liqData.tLiqPrefix * childWidth;
                // It's okay to round down here. That's incorporated in the rate curve.
                uint64 utilX64 = uint64((totalTLiq << 64) / totalMLiq);
                leftWeight = feeData.splitConfig.calculateRateX64(utilX64);
            }
        }
        {
            uint256 rightMLiq = right.subtreeMLiq + myMLiq;
            uint256 totalMLiq = rightMLiq + liqData.mLiqPrefix * childWidth;
            if (totalMLiq == 0) {
                rightWeight = feeData.splitConfig.calculateRateX64(0);
            } else {
                uint256 rightTLiq = right.subtreeTLiq + myTLiq;
                uint256 totalTLiq = rightTLiq + liqData.tLiqPrefix * childWidth;
                // It's okay to round down here. That's incorporated in the rate curve.
                uint64 utilX64 = uint64((totalTLiq << 64) / totalMLiq);
                // Important to incorporate tliq in the weight so the same ratio, but different tLiqs
                // pay proportionally.
                rightWeight = feeData.splitConfig.calculateRateX64(utilX64);
            }
        }
    }

    /// @notice Called on nodes that are the deepest we'll walk for their subtree (prop children) to charge them
    /// their subtree exact fees, and report their total amounts paid.
    /// @dev This assumes the prefix does not include the current node's liquidity.
    function chargeTrueFeeRate(
        Key key,
        Node storage node,
        Data memory data
    )
        internal
        returns (
            uint256 colMakerXRateX128,
            uint256 colMakerYRateX128,
            uint256 colTakerXRateX128,
            uint256 colTakerYRateX128
        )
    {
        uint24 width = key.width();
        // We use the liq ratio to calculate the true fee rate the entire column should pay.
        uint256 totalMLiq = width * data.liq.mLiqPrefix + node.liq.subtreeMLiq;
        uint256 totalTLiq = width * data.liq.tLiqPrefix + node.liq.subtreeTLiq;
        if (totalMLiq == 0 || totalTLiq == 0) {
            // There is no maker or taker liq in this entire column, so no fees to charge, no fee rates to update,
            // no unclaimeds to propogate down.
            // But we do have to return 1 for the taker rates to indicate we've actually calculated them.
            // This is okay because without any taker liq in this subtree (or any subtree above) no one will pay this 1.
            // And makers aren't trying to claim this dust.
            // The only time it actually manifests is in a subtree above that actually has takers. Their rates will be
            // higher by at most the subtree nodes visited which is at most 21. This is dwarfed by anything meaningful.
            return (0, 0, 1, 1);
        }
        uint256 timeDiff = uint128(block.timestamp) - data.timestamp; // Convert to 256 for next mult
        uint256 takerRateX64 = timeDiff * data.fees.rateConfig.calculateRateX64(uint64((totalTLiq << 64) / totalMLiq));
        // Then we use the total column x and y borrows to calculate the total fees paid.
        (uint256 totalXBorrows, uint256 totalYBorrows) = data.computeBorrows(key, data.liq.tLiqPrefix, true);
        totalXBorrows += node.liq.subtreeBorrowedX;
        totalYBorrows += node.liq.subtreeBorrowedY;
        uint256 colXPaid = FullMath.mulX64(totalXBorrows, takerRateX64, true);
        uint256 colYPaid = FullMath.mulX64(totalYBorrows, takerRateX64, true);

        // Determine our column rates.
        // We round down but add one to ensure that taker rates are never 0 if visited.
        // This is important for indicating no fees vs. uncalculated fees.
        colTakerXRateX128 = FullMath.mulDiv(colXPaid, 1 << 128, totalTLiq) + 1;
        colTakerYRateX128 = FullMath.mulDiv(colYPaid, 1 << 128, totalTLiq) + 1;
        colMakerXRateX128 = FullMath.mulDiv(colXPaid, 1 << 128, totalMLiq);
        colMakerYRateX128 = FullMath.mulDiv(colYPaid, 1 << 128, totalMLiq);
        // Now add this to our node's fee accounting.
        node.fees.takerXFeesPerLiqX128 += colTakerXRateX128;
        node.fees.takerYFeesPerLiqX128 += colTakerYRateX128;
        node.fees.makerXFeesPerLiqX128 += colMakerXRateX128;
        node.fees.makerYFeesPerLiqX128 += colMakerYRateX128;
        uint256 compoundingLiq = width * (node.liq.mLiq - node.liq.ncLiq);
        node.fees.xCFees = add128Fees(
            node.fees.xCFees,
            FullMath.mulX128(colMakerXRateX128, compoundingLiq, false),
            data,
            true
        );
        node.fees.yCFees = add128Fees(
            node.fees.yCFees,
            FullMath.mulX128(colMakerYRateX128, compoundingLiq, false),
            data,
            false
        );
        // Then we calculate the children's fees and split.
        if (!key.isLeaf()) {
            (Key leftChild, Key rightChild) = key.children();
            Node storage leftNode = data.node(leftChild);
            Node storage rightNode = data.node(rightChild);

            /// The earnings to split.
            uint256 childrenTLiq = leftNode.liq.subtreeTLiq + rightNode.liq.subtreeTLiq;
            uint256 childrenXPaid = FullMath.mulX128(colTakerXRateX128, childrenTLiq, true);
            uint256 childrenYPaid = FullMath.mulX128(colTakerYRateX128, childrenTLiq, true);
            uint256 childrenMLiq = leftNode.liq.subtreeMLiq + rightNode.liq.subtreeMLiq;
            uint256 childrenXEarned = FullMath.mulX128(colMakerXRateX128, childrenMLiq, false);
            uint256 childrenYEarned = FullMath.mulX128(colMakerYRateX128, childrenMLiq, false);
            childSplit(
                data,
                node,
                leftNode,
                rightNode,
                width / 2,
                childrenXPaid,
                childrenYPaid,
                childrenXEarned,
                childrenYEarned
            );
        }
    }

    // Split the paid amounts and earned amounts into this node's children's unclaimed/unpaid.
    function childSplit(
        Data memory data,
        Node storage node,
        Node storage leftNode,
        Node storage rightNode,
        uint24 childWidth,
        uint256 xPaid,
        uint256 yPaid,
        uint256 xEarned,
        uint256 yEarned
    ) internal {
        // We split the earnings by the left and right weights.
        (uint256 leftWeight, uint256 rightWeight) = getLeftRightWeights(
            data.liq,
            data.fees,
            node.liq,
            leftNode.liq,
            rightNode.liq,
            childWidth
        );

        // Calculate x weighted split.
        uint256 leftBorrowWeight = leftWeight * leftNode.liq.subtreeBorrowedX;
        uint256 rightBorrowWeight = rightWeight * rightNode.liq.subtreeBorrowedX;
        uint256 leftPaid;
        uint256 leftEarned;
        if (leftBorrowWeight == rightBorrowWeight) {
            // We special case here to catch when both weights are zero, but check equality
            // to conveniently cheapen other cases where this applies as well.
            // If the case is zero, zero, then there will be no paids to split, so no fees are lost.
            leftPaid = xPaid / 2;
            leftEarned = xEarned / 2;
        } else if (leftBorrowWeight == 0) {
            leftPaid = 0;
            leftEarned = 0;
        } else if (rightBorrowWeight == 0) {
            leftPaid = xPaid;
            leftEarned = xEarned;
        } else {
            uint256 leftRatioX256 = FullMath.mulDivX256(leftBorrowWeight, leftBorrowWeight + rightBorrowWeight, false);
            leftPaid = FullMath.mulX256(xPaid, leftRatioX256, false);
            leftEarned = FullMath.mulX256(xEarned, leftRatioX256, false);
        }
        leftNode.fees.unpaidTakerXFees += uint128(leftPaid);
        rightNode.fees.unpaidTakerXFees += uint128(xPaid - leftPaid);
        leftNode.fees.unclaimedMakerXFees += uint128(leftEarned);
        rightNode.fees.unclaimedMakerXFees += uint128(xEarned - leftEarned);

        // Repeat for Y.
        leftBorrowWeight = leftWeight * leftNode.liq.subtreeBorrowedY;
        rightBorrowWeight = rightWeight * rightNode.liq.subtreeBorrowedY;
        if (leftBorrowWeight == rightBorrowWeight) {
            leftPaid = yPaid / 2;
            leftEarned = yEarned / 2;
        } else if (leftBorrowWeight == 0) {
            leftPaid = 0;
            leftEarned = 0;
        } else if (rightBorrowWeight == 0) {
            leftPaid = yPaid;
            leftEarned = yEarned;
        } else {
            uint256 leftRatioX256 = FullMath.mulDivX256(leftBorrowWeight, leftBorrowWeight + rightBorrowWeight, false);
            leftPaid = FullMath.mulX256(yPaid, leftRatioX256, false);
            leftEarned = FullMath.mulX256(yEarned, leftRatioX256, false);
        }
        leftNode.fees.unpaidTakerYFees += uint128(leftPaid);
        rightNode.fees.unpaidTakerYFees += uint128(yPaid - leftPaid);
        leftNode.fees.unclaimedMakerYFees += uint128(leftEarned);
        rightNode.fees.unclaimedMakerYFees += uint128(yEarned - leftEarned);
    }

    /// Increase fees by an amount but limit the output the uint128, giving the extra to the caller through
    /// the data balances.
    function add128Fees(uint128 a, uint256 b, Data memory data, bool isX) internal pure returns (uint128 res) {
        if (a + b > type(uint128).max) {
            // If the result overflows, cap it at uint128 max and add the excess to the user's received balances.
            res = type(uint128).max;
            // Any pool that has fees actually greater than int256.max must be so contrived we don't care if it
            // fails in a way that doesn't affect other pools. So we do an unsafe cast here.
            uint256 excess = a + b - type(uint128).max;
            if (isX) {
                data.xBalance -= int256(excess);
            } else {
                data.yBalance -= int256(excess);
            }
        } else {
            res = uint128(a + b);
        }
    }
}
