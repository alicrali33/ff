// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { SmoothRateCurveConfig, SmoothRateCurveLib } from "Commons/Math/SmoothRateCurveLib.sol";
import { Key } from "../tree/Key.sol";
import { Phase } from "../tree/Route.sol";
import { Data } from "./Data.sol";
import { Node } from "./Node.sol";
import { LiqType, LiqData, LiqDataLib } from "./Liq.sol";
import { FullMath } from "../FullMath.sol";
import { FeeData, FeeDataLib, FeeWalker } from "./Fee.sol";
import { Asset, AssetNode } from "../Asset.sol";
import { PoolInfo, Pool, PoolLib } from "../Pool.sol";
import { Store } from "../Store.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";

/// We just need to track earnings and balances
struct ViewData {
    address poolAddr;
    bytes32 poolStore;
    bytes32 assetStore;
    uint160 sqrtPriceX96;
    uint128 timestamp; // The last time the pool was modified.
    FeeData fees;
    LiqData liq;
    /* Outputs */
    uint256 liqBalanceX;
    uint256 liqBalanceY;
    uint256 earningsX;
    uint256 earningsY;
    // Down helpers
    uint256 leftChildUnclaimedX;
    uint256 leftChildUnclaimedY;
    uint256 rightChildUnclaimedX;
    uint256 rightChildUnclaimedY;
    uint256 leftChildUnpaidX;
    uint256 leftChildUnpaidY;
    uint256 rightChildUnpaidX;
    uint256 rightChildUnpaidY;
    uint256 lcaRightUnclaimedX;
    uint256 lcaRightUnclaimedY;
    uint256 lcaRightUnpaidX;
    uint256 lcaRightUnpaidY;
}

using ViewDataImpl for ViewData global;

library ViewDataImpl {
    function make(PoolInfo memory pInfo, Asset storage asset) internal view returns (ViewData memory) {
        Pool storage pool = Store.pool(pInfo.poolAddr);
        bytes32 poolSlot;
        assembly {
            poolSlot := pool.slot
        }
        bytes32 assetSlot;
        assembly {
            assetSlot := asset.slot
        }
        uint160 currentSqrtPriceX96 = PoolLib.getSqrtPriceX96(pInfo.poolAddr);

        return
            ViewData({
                poolAddr: pInfo.poolAddr,
                poolStore: poolSlot,
                assetStore: assetSlot,
                sqrtPriceX96: currentSqrtPriceX96,
                timestamp: pool.timestamp,
                liq: LiqDataLib.make(asset, pInfo, 0),
                fees: FeeDataLib.make(pInfo),
                // Outputs
                liqBalanceX: 0,
                liqBalanceY: 0,
                earningsX: 0,
                earningsY: 0,
                // Helpers
                leftChildUnclaimedX: 0,
                leftChildUnclaimedY: 0,
                rightChildUnclaimedX: 0,
                rightChildUnclaimedY: 0,
                leftChildUnpaidX: 0,
                leftChildUnpaidY: 0,
                rightChildUnpaidX: 0,
                rightChildUnpaidY: 0,
                lcaRightUnclaimedX: 0,
                lcaRightUnclaimedY: 0,
                lcaRightUnpaidX: 0,
                lcaRightUnpaidY: 0
            });
    }

    function computeBorrows(
        ViewData memory self,
        Key key,
        uint128 liq,
        bool roundUp
    ) internal pure returns (uint256 xBorrows, uint256 yBorrows) {
        if (liq == 0) {
            return (0, 0);
        }
        (int24 lowTick, int24 highTick) = key.ticks(self.fees.rootWidth, self.fees.tickSpacing);

        int24 gmTick = lowTick + (highTick - lowTick) / 2; // The tick of the geometric mean.

        uint160 lowSqrtPriceX96 = TickMath.getSqrtPriceAtTick(lowTick);
        uint160 gmSqrtPriceX96 = TickMath.getSqrtPriceAtTick(gmTick);
        uint160 highSqrtPriceX96 = TickMath.getSqrtPriceAtTick(highTick);
        xBorrows = SqrtPriceMath.getAmount0Delta(gmSqrtPriceX96, highSqrtPriceX96, liq, roundUp);
        yBorrows = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, gmSqrtPriceX96, liq, roundUp);
    }

    function computeBalances(
        ViewData memory self,
        Key key,
        uint128 liq,
        bool roundUp
    ) internal pure returns (uint256 xBalance, uint256 yBalance) {
        if (liq == 0) {
            return (0, 0);
        }
        (int24 lowTick, int24 highTick) = key.ticks(self.fees.rootWidth, self.fees.tickSpacing);
        (xBalance, yBalance) = PoolLib.getAmounts(self.sqrtPriceX96, lowTick, highTick, liq, roundUp);
    }

    /* Helpers */

    function node(ViewData memory self, Key key) internal view returns (Node storage) {
        Pool storage pool;
        bytes32 poolSlot = self.poolStore;
        assembly {
            pool.slot := poolSlot
        }
        return pool.nodes[key];
    }

    function assetNode(ViewData memory self, Key key) internal view returns (AssetNode storage) {
        Asset storage asset;
        bytes32 assetSlot = self.assetStore;
        assembly {
            asset.slot := assetSlot
        }
        return asset.nodes[key];
    }
}

library ViewWalker {
    using SmoothRateCurveLib for SmoothRateCurveConfig;

    // On the way down, we collect earnings for the existing fees earned and the existing unclaimed balances.
    // Then on visit nodes we pay any true fee rates. Then we add the liquidity balances.
    function down(Key key, bool visit, ViewData memory data) internal view {
        // On the way down, we accumulate the prefixes and claim fees.
        Node storage node = data.node(key);
        AssetNode storage aNode = data.assetNode(key);

        // Inherit the unclaimed/unpaid from the parent node since we can't assign.
        (int24 low, int24 high) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        uint256 unclaimedX;
        uint256 unclaimedY;
        uint256 unpaidX;
        uint256 unpaidY;
        if (key.isLeft()) {
            unclaimedX = data.leftChildUnclaimedX + node.fees.unclaimedMakerXFees;
            unclaimedY = data.leftChildUnclaimedY + node.fees.unclaimedMakerYFees;
            unpaidX = data.leftChildUnpaidX + node.fees.unpaidTakerXFees;
            unpaidY = data.leftChildUnpaidY + node.fees.unpaidTakerYFees;
        } else {
            unclaimedX = data.rightChildUnclaimedX + node.fees.unclaimedMakerXFees;
            unclaimedY = data.rightChildUnclaimedY + node.fees.unclaimedMakerYFees;
            unpaidX = data.rightChildUnpaidX + node.fees.unpaidTakerXFees;
            unpaidY = data.rightChildUnpaidY + node.fees.unpaidTakerYFees;
        }

        // If we're visiting, we just worry about our own earnings, as we'll have no children to propogate to.
        // Plus we don't want to overwrite the unclaims/unpaids inherited by our sibling.
        if (visit) {
            // First we claim the existing fee earnings.
            claimCurrentFees(node, aNode, data, low, high);

            // Now claim the unclaimed/unpaid fees.
            if (data.liq.liqType == LiqType.TAKER) {
                data.earningsX += FullMath.mulDivRoundingUp(unpaidX, aNode.sliq, node.liq.subtreeTLiq);
                data.earningsY += FullMath.mulDivRoundingUp(unpaidY, aNode.sliq, node.liq.subtreeTLiq);
            } else {
                data.earningsX += FullMath.mulDiv(unclaimedX, aNode.sliq, node.liq.subtreeMLiq);
                data.earningsY += FullMath.mulDiv(unclaimedY, aNode.sliq, node.liq.subtreeMLiq);
            }

            // Now charge the true fee rate which will always be the case with visits.
            // Note that the prefix has not been added because we visit the visit sibling before the prop
            // sibling on the way down.
            chargeTrueFeeRate(key, node, aNode, data);

            // Now claim the liquidity balances.
            bool roundUp = (data.liq.liqType == LiqType.TAKER);
            uint128 liq = (data.liq.liqType == LiqType.MAKER)
                ? uint128(FullMath.mulDiv(node.liq.mLiq - node.liq.ncLiq, aNode.sliq, node.liq.shares))
                : aNode.sliq;
            (uint256 x, uint256 y) = data.computeBalances(key, liq, roundUp);
            data.liqBalanceX += x;
            data.liqBalanceY += y;
        } else {
            // If we're not visiting, we just have to propogate down the unclaims/unpaids to the visit nodes.
            uint24 width = key.width();
            // Takers
            uint256 nodeLiq;
            if (node.liq.subtreeTLiq != 0) {
                nodeLiq = node.liq.tLiq * width;
                unpaidX -= FullMath.mulDiv(unpaidX, nodeLiq, node.liq.subtreeTLiq);
                unpaidY -= FullMath.mulDiv(unpaidY, nodeLiq, node.liq.subtreeTLiq);
            }

            // Makers
            if (node.liq.subtreeMLiq != 0) {
                nodeLiq = node.liq.mLiq * width;
                unclaimedX -= FullMath.mulDivRoundingUp(unclaimedX, nodeLiq, node.liq.subtreeMLiq);
                unclaimedY -= FullMath.mulDivRoundingUp(unclaimedY, nodeLiq, node.liq.subtreeMLiq);
            }

            // Now split fees before updating prefixes.
            (Key leftChild, Key rightChild) = key.children();
            Node storage leftNode = data.node(leftChild);
            Node storage rightNode = data.node(rightChild);
            uint24 childWidth = leftChild.width();

            // We split the earnings by the left and right weights.
            (uint256 leftWeight, uint256 rightWeight) = FeeWalker.getLeftRightWeights(
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
                leftPaid = unpaidX / 2;
                leftEarned = unclaimedX / 2;
            } else if (leftBorrowWeight == 0) {
                leftPaid = 0;
                leftEarned = 0;
            } else if (rightBorrowWeight == 0) {
                leftPaid = unpaidX;
                leftEarned = unclaimedX;
            } else {
                uint256 leftRatioX256 = FullMath.mulDivX256(
                    leftBorrowWeight,
                    leftBorrowWeight + rightBorrowWeight,
                    false
                );
                leftPaid = FullMath.mulX256(unpaidX, leftRatioX256, false);
                leftEarned = FullMath.mulX256(unclaimedX, leftRatioX256, false);
            }
            data.leftChildUnpaidX = leftPaid;
            data.rightChildUnpaidY = unpaidX - leftPaid;
            data.leftChildUnclaimedX = leftEarned;
            data.rightChildUnclaimedX = unclaimedX - leftEarned;

            // Repeat for Y.
            leftBorrowWeight = leftWeight * leftNode.liq.subtreeBorrowedY;
            rightBorrowWeight = rightWeight * rightNode.liq.subtreeBorrowedY;
            if (leftBorrowWeight == rightBorrowWeight) {
                leftPaid = unpaidY / 2;
                leftEarned = unclaimedY / 2;
            } else if (leftBorrowWeight == 0) {
                leftPaid = 0;
                leftEarned = 0;
            } else if (rightBorrowWeight == 0) {
                leftPaid = unpaidY;
                leftEarned = unclaimedY;
            } else {
                uint256 leftRatioX256 = FullMath.mulDivX256(
                    leftBorrowWeight,
                    leftBorrowWeight + rightBorrowWeight,
                    false
                );
                leftPaid = FullMath.mulX256(unpaidY, leftRatioX256, false);
                leftEarned = FullMath.mulX256(unclaimedY, leftRatioX256, false);
            }
            data.leftChildUnpaidY = leftPaid;
            data.rightChildUnpaidY = unpaidY - leftPaid;
            data.leftChildUnclaimedY = leftEarned;
            data.rightChildUnclaimedY = unclaimedY - leftEarned;

            // Now we can add to the prefix since we're not visiting.
            data.liq.mLiqPrefix += node.liq.mLiq;
            data.liq.tLiqPrefix += node.liq.tLiq;
        }
    }

    function phase(Phase walkPhase, ViewData memory data) internal pure {
        // Even
        if (walkPhase == Phase.ROOT_DOWN) {
            data.lcaRightUnclaimedX = data.rightChildUnclaimedX;
            data.lcaRightUnclaimedY = data.rightChildUnclaimedY;
            data.lcaRightUnpaidX = data.rightChildUnpaidX;
            data.lcaRightUnpaidY = data.rightChildUnpaidY;
            data.liq.rootMLiq = data.liq.mLiqPrefix;
            data.liq.rootTLiq = data.liq.tLiqPrefix;
        } else if (walkPhase == Phase.LEFT_DOWN) {
            // Note that this phase is called REGARDLESS if there was a left route to walk or not.
            data.rightChildUnclaimedX = data.lcaRightUnclaimedX;
            data.rightChildUnclaimedY = data.lcaRightUnclaimedY;
            data.rightChildUnpaidX = data.lcaRightUnpaidX;
            data.rightChildUnpaidY = data.lcaRightUnpaidY;
            data.liq.mLiqPrefix = data.liq.rootMLiq;
            data.liq.tLiqPrefix = data.liq.rootTLiq;
        }
    }

    /* Helpers */

    function claimCurrentFees(
        Node storage node,
        AssetNode storage aNode,
        ViewData memory data,
        int24 low,
        int24 high
    ) internal view {
        (uint256 newFeeGrowthInside0X128, uint256 newFeeGrowthInside1X128) = PoolLib.getInsideFees(
            data.poolAddr,
            low,
            high
        );
        uint256 fee0DiffX128 = newFeeGrowthInside0X128 - node.liq.feeGrowthInside0X128;
        uint256 fee1DiffX128 = newFeeGrowthInside1X128 - node.liq.feeGrowthInside1X128;
        if (data.liq.liqType == LiqType.MAKER) {
            // We just claim our shares.
            // If the sliq and shares are zero, you should fail anyways.
            data.earningsX += FullMath.mulDiv(node.fees.xCFees, aNode.sliq, node.liq.shares);
            data.earningsY += FullMath.mulDiv(node.fees.yCFees, aNode.sliq, node.liq.shares);
        } else if (data.liq.liqType == LiqType.MAKER_NC) {
            data.earningsX += FullMath.mulX128(
                aNode.sliq,
                fee0DiffX128 + node.fees.makerXFeesPerLiqX128 - aNode.fee0CheckX128,
                false
            );
            data.earningsY += FullMath.mulX128(
                aNode.sliq,
                fee1DiffX128 + node.fees.makerYFeesPerLiqX128 - aNode.fee1CheckX128,
                false
            );
        } else {
            data.earningsX += FullMath.mulX128(
                aNode.sliq,
                fee0DiffX128 + node.fees.takerXFeesPerLiqX128 - aNode.fee0CheckX128,
                true
            );
            data.earningsY += FullMath.mulX128(
                aNode.sliq,
                fee1DiffX128 + node.fees.takerYFeesPerLiqX128 - aNode.fee1CheckX128,
                true
            );
        }
    }

    /// @notice Called on visited nodes to charge them their subtree exact fees.
    /// Because this is for viewing, we don't need to worry about the subtree unclaim/unpaids and just
    /// charge the rates. We DO NOT add the earnings to data here.
    /// @dev This assumes the prefix does not include the current node's liquidity.
    function chargeTrueFeeRate(
        Key key,
        Node storage node,
        AssetNode storage aNode,
        ViewData memory data
    ) internal view {
        uint24 width = key.width();
        // We use the liq ratio to calculate the true fee rate the entire column should pay.
        uint256 totalMLiq = width * data.liq.mLiqPrefix + node.liq.subtreeMLiq;
        uint256 totalTLiq = width * data.liq.tLiqPrefix + node.liq.subtreeTLiq;
        if (totalMLiq == 0 || totalTLiq == 0) {
            return;
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
        // We don't need this for view but we do this to match the modifying version.
        uint256 colTakerXRateX128 = FullMath.mulDiv(colXPaid, 1 << 128, totalTLiq) + 1;
        uint256 colTakerYRateX128 = FullMath.mulDiv(colYPaid, 1 << 128, totalTLiq) + 1;
        uint256 colMakerXRateX128 = FullMath.mulDiv(colXPaid, 1 << 128, totalMLiq);
        uint256 colMakerYRateX128 = FullMath.mulDiv(colYPaid, 1 << 128, totalMLiq);

        if (data.liq.liqType == LiqType.TAKER) {
            data.earningsX += FullMath.mulX128(aNode.sliq, colTakerXRateX128, true);
            data.earningsY += FullMath.mulX128(aNode.sliq, colTakerYRateX128, true);
        } else {
            // Compounding liq would earn the same amount here.
            data.earningsX += FullMath.mulX128(aNode.sliq, colMakerXRateX128, false);
            data.earningsY += FullMath.mulX128(aNode.sliq, colMakerYRateX128, false);
        }
    }
}
