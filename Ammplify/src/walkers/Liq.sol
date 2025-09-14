// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Key } from "../tree/Key.sol";
import { Node } from "./Node.sol";
import { Data } from "./Data.sol";
import { Phase } from "../tree/Route.sol";
import { FullMath } from "../FullMath.sol";
import { Asset, AssetNode } from "../Asset.sol";
import { PoolInfo, PoolLib } from "../Pool.sol";
import { FeeLib } from "../Fee.sol";
import { FeeWalker } from "./Fee.sol";
import { SafeCast } from "Commons/Math/Cast.sol";

enum LiqType {
    MAKER,
    MAKER_NC,
    TAKER
}

/// Data we need to persist for liquidity accounting.
struct LiqNode {
    uint128 mLiq;
    uint128 tLiq;
    uint128 ncLiq;
    uint128 shares; // Total shares of compounding maker liq.
    uint256 subtreeMLiq;
    uint256 subtreeTLiq;
    uint256 subtreeBorrowedX; // Taker required for fee calculation.
    uint256 subtreeBorrowedY;
    // Swap fee earnings checkpointing
    uint256 feeGrowthInside0X128;
    uint256 feeGrowthInside1X128;
    // Liq Redistribution
    uint128 borrowed;
    uint128 lent;
    int128 preBorrow;
    int128 preLend;
    // Dirty bit for liquidity modifications.
    bool dirty;
}

using LiqNodeImpl for LiqNode global;

library LiqNodeImpl {
    function compound(LiqNode storage self, uint128 compoundedLiq, uint24 width) internal {
        if (compoundedLiq == 0) {
            return;
        }
        self.mLiq += compoundedLiq;
        self.subtreeMLiq += width * compoundedLiq;
        self.dirty = true;
    }

    /// The net liquidity owned by the node's position.
    function net(LiqNode storage self) internal view returns (int128) {
        // Ensure liquidity at each node won't be greater than 2^127 - 1.
        return SafeCast.toInt128(self.borrowed + self.mLiq) - SafeCast.toInt128(self.tLiq + self.lent);
    }

    /// @notice Splits balance between compounding and non-compounding maker liquidity.
    /// @dev Callers should check if the mliq is non-zero first.
    /// @return c The nominal amount of fees collected for compounding makers.
    /// @return nonCX128 The rate earned per non-compounding liq.
    function splitMakerFees(LiqNode storage self, uint256 nominal) internal view returns (uint128 c, uint256 nonCX128) {
        // Every mliq earns the same rate here. We round down for everyone to avoid overcollection of dust.
        nonCX128 = (uint256(nominal) << 128) / self.mLiq;
        c = uint128(nominal - FullMath.mulX128(nonCX128, self.ncLiq, true)); // Round up to subtract down.
    }
}

struct LiqData {
    LiqType liqType;
    uint128 liq; // The target liquidity to set the asset node's liq to.
    uint128 compoundThreshold; // The min liquidity worth compounding.
    // Prefix info
    uint128 mLiqPrefix; // Current prefix of maker liquidity.
    uint128 tLiqPrefix; // Current prefix of taker liquidity.
    uint128 rootMLiq; // The root to LCA maker liquidity.
    uint128 rootTLiq; // The root to LCA taker liquidity.
    uint128 leftMLiqPrefix; // The final prefix after the left walk down.
    uint128 leftTLiqPrefix;
    uint128 rightMLiqPrefix; // The final prefix after the right walk down.
    uint128 rightTLiqPrefix;
}

library LiqDataLib {
    function make(
        Asset storage asset,
        PoolInfo memory pInfo,
        uint128 targetLiq
    ) internal view returns (LiqData memory) {
        return
            LiqData({
                liqType: asset.liqType,
                liq: targetLiq,
                compoundThreshold: FeeLib.getCompoundThreshold(pInfo.poolAddr),
                mLiqPrefix: 0,
                tLiqPrefix: 0,
                rootMLiq: 0,
                rootTLiq: 0,
                leftMLiqPrefix: 0,
                leftTLiqPrefix: 0,
                rightMLiqPrefix: 0,
                rightTLiqPrefix: 0
            });
    }
}

library LiqWalker {
    error InsufficientBorrowLiquidity(int256 netLiq);

    /// Data useful when visiting/propogating to a node.
    struct LiqIter {
        Key key;
        bool visit;
        uint24 width;
        int24 lowTick;
        int24 highTick;
    }

    function up(Key key, bool visit, Data memory data) internal {
        Node storage node = data.node(key);

        LiqIter memory iter;
        {
            (int24 lowTick, int24 highTick) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
            iter = LiqIter({ key: key, visit: visit, width: key.width(), lowTick: lowTick, highTick: highTick });
        }

        // Compound first.
        compound(iter, node, data);

        // Do the modifications.
        if (visit) {
            modify(iter, node, data, data.liq.liq);
        } else {
            // If propogating, we can't be at a leaf.
            (Key lk, Key rk) = key.children();
            Node storage lNode = data.node(lk);
            Node storage rNode = data.node(rk);
            node.liq.subtreeMLiq = lNode.liq.subtreeMLiq + rNode.liq.subtreeMLiq + node.liq.mLiq * iter.width;
            node.liq.subtreeTLiq = lNode.liq.subtreeTLiq + rNode.liq.subtreeTLiq + node.liq.tLiq * iter.width;
        }

        // Make sure our liquidity is solvent at each node.
        solveLiq(iter, node, data);
    }

    function phase(Phase walkPhase, Data memory data) internal pure {
        // It's a little strange but the liq prefixes are updated by the FeeWalker.
        // This is because the ordering between fee updates and prefix updates is important to get right.
        if (walkPhase == Phase.ROOT_DOWN) {
            data.liq.rootMLiq = data.liq.mLiqPrefix;
            data.liq.rootTLiq = data.liq.tLiqPrefix;
        } else if (walkPhase == Phase.LEFT_DOWN) {
            data.liq.leftMLiqPrefix = data.liq.mLiqPrefix;
            data.liq.leftTLiqPrefix = data.liq.tLiqPrefix;
            data.liq.mLiqPrefix = data.liq.rootMLiq;
            data.liq.tLiqPrefix = data.liq.rootTLiq;
        } else if (walkPhase == Phase.RIGHT_DOWN) {
            data.liq.rightMLiqPrefix = data.liq.mLiqPrefix;
            data.liq.rightTLiqPrefix = data.liq.tLiqPrefix;
        } else if (walkPhase == Phase.PRE_UP) {
            data.liq.mLiqPrefix = data.liq.leftMLiqPrefix;
            data.liq.tLiqPrefix = data.liq.leftTLiqPrefix;
        } else if (walkPhase == Phase.LEFT_UP) {
            data.liq.mLiqPrefix = data.liq.rightMLiqPrefix;
            data.liq.tLiqPrefix = data.liq.rightTLiqPrefix;
        }
    }

    /* Helpers */

    /// Compounding's first step is to actually collect the base pool fees (for both makers and takers).
    /// So this is a crucial step to always call when walking over any node.
    /// @dev We update the taker fees here
    function compound(LiqIter memory iter, Node storage node, Data memory data) internal {
        // Collect fees here BUT these may not be this node's actual fees to compound because it could be BORROWED liq
        // from a parent node. Therefore, we have to rely on inside fee rates to calc compounds despite potentially
        // having more fees than that.
        if (node.liq.net() > 0) {
            PoolLib.collect(data.poolAddr, iter.lowTick, iter.highTick, true);
        }
        // Now we calculate what swap fees are earned by makers and owed by the taker borrows.
        (uint256 newFeeGrowthInside0X128, uint256 newFeeGrowthInside1X128) = PoolLib.getInsideFees(
            data.poolAddr,
            iter.lowTick,
            iter.highTick
        );
        uint256 feeDiffInside0X128 = newFeeGrowthInside0X128 - node.liq.feeGrowthInside0X128;
        uint256 feeDiffInside1X128 = newFeeGrowthInside1X128 - node.liq.feeGrowthInside1X128;
        node.liq.feeGrowthInside0X128 = newFeeGrowthInside0X128;
        node.liq.feeGrowthInside1X128 = newFeeGrowthInside1X128;
        // Any takers here need to be charged.
        node.fees.takerXFeesPerLiqX128 += feeDiffInside0X128;
        node.fees.takerYFeesPerLiqX128 += feeDiffInside1X128;

        // If we have no maker liq in this node, then there is nothing to compound.
        if (node.liq.mLiq == 0) return;

        // Otherwise, the fees should have been collected (or are avilable from collateral)
        // and we can compound.
        uint256 x = FullMath.mulX128(node.liq.mLiq, feeDiffInside0X128, false);
        uint256 y = FullMath.mulX128(node.liq.mLiq, feeDiffInside1X128, false);

        uint256 nonCX128;
        (x, nonCX128) = node.liq.splitMakerFees(x);
        node.fees.makerXFeesPerLiqX128 += nonCX128;
        node.fees.xCFees = FeeWalker.add128Fees(node.fees.xCFees, x, data, true);

        (y, nonCX128) = node.liq.splitMakerFees(y);
        node.fees.makerYFeesPerLiqX128 += nonCX128;
        node.fees.yCFees = FeeWalker.add128Fees(node.fees.yCFees, y, data, false);

        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            iter.lowTick,
            iter.highTick,
            node.fees.xCFees,
            node.fees.yCFees,
            data.sqrtPriceX96
        );
        if (assignableLiq < data.liq.compoundThreshold) {
            // Not worth compounding right now.
            return;
        }
        node.liq.compound(assignableLiq, iter.width);
        node.fees.xCFees = leftoverX;
        node.fees.yCFees = leftoverY;
    }

    function modify(LiqIter memory iter, Node storage node, Data memory data, uint128 targetLiq) internal {
        AssetNode storage aNode = data.assetNode(iter.key);
        // First we collect fees for the position (not the pool which happens in compound).
        // Fee collection happens automatically for compounding liq when modifying liq.
        collectFees(aNode, node, data);

        // Then we do the liquidity modification.
        uint128 sliq = aNode.sliq; // Our current liquidity balance.
        bool dirty = true;
        uint128 targetSliq = targetLiq; // Only changed in the MAKER case

        if (data.liq.liqType == LiqType.MAKER) {
            uint128 compoundingLiq = 0;
            uint128 currentLiq = 0;
            targetSliq = targetLiq; // Shares start equal to liq.
            if (node.liq.shares != 0) {
                // For adding liquidity, we need to consider existing fees
                // and what amount of equivalent liq they're worth.
                uint128 equivLiq = PoolLib.getEquivalentLiq(
                    iter.lowTick,
                    iter.highTick,
                    node.fees.xCFees,
                    node.fees.yCFees,
                    data.sqrtPriceX96,
                    true
                );
                // If this compounding liq balance overflows, the pool cannot be on reasonable tokens,
                // hence we allow the overflow error to revert. This won't affect other pools.
                compoundingLiq = node.liq.mLiq - node.liq.ncLiq + equivLiq;
                currentLiq = uint128(FullMath.mulDiv(compoundingLiq, sliq, node.liq.shares));
                // The shares we'll have afterwards.
                targetSliq = uint128(FullMath.mulDiv(node.liq.shares, targetLiq, compoundingLiq));
            }
            if (currentLiq < targetLiq) {
                uint128 liqDiff = targetLiq - currentLiq;
                node.liq.mLiq += liqDiff;
                node.liq.shares += targetSliq - sliq;
                node.liq.subtreeMLiq += iter.width * liqDiff;
                (uint256 xNeeded, uint256 yNeeded) = data.computeBalances(iter.key, liqDiff, true);
                data.xBalance += int256(xNeeded);
                data.yBalance += int256(yNeeded);
            } else if (currentLiq > targetLiq) {
                // When subtracting liquidity, since we've already considered the equiv liq in adding,
                // we can just remove the share-proportion of liq and fees (not equiv).
                compoundingLiq = node.liq.mLiq - node.liq.ncLiq;
                uint128 sliqDiff = sliq - targetSliq;
                uint256 shareRatioX256 = FullMath.mulDivX256(sliqDiff, node.liq.shares, false);
                uint128 liq = uint128(FullMath.mulX256(compoundingLiq, shareRatioX256, false));
                node.liq.mLiq -= liq;
                node.liq.shares -= sliqDiff;
                node.liq.subtreeMLiq -= iter.width * liq;
                uint256 xClaim = FullMath.mulX256(node.fees.xCFees, shareRatioX256, false);
                node.fees.xCFees -= uint128(xClaim);
                data.xBalance -= int256(xClaim);
                uint256 yClaim = FullMath.mulX256(node.fees.yCFees, shareRatioX256, false);
                node.fees.yCFees -= uint128(yClaim);
                data.yBalance -= int256(yClaim);
                // Now we claim the balances from the liquidity itself.
                (uint256 xOwed, uint256 yOwed) = data.computeBalances(iter.key, liq, false);
                data.xBalance -= int256(xOwed);
                data.yBalance -= int256(yOwed);
            } else {
                dirty = false;
            }
        } else if (data.liq.liqType == LiqType.MAKER_NC) {
            if (sliq < targetLiq) {
                uint128 liqDiff = targetLiq - sliq;
                sliq = targetLiq;
                node.liq.mLiq += liqDiff;
                node.liq.ncLiq += liqDiff;
                node.liq.subtreeMLiq += iter.width * liqDiff;
                (uint256 xNeeded, uint256 yNeeded) = data.computeBalances(iter.key, liqDiff, true);
                data.xBalance += int256(xNeeded);
                data.yBalance += int256(yNeeded);
            } else if (sliq > targetLiq) {
                uint128 liqDiff = sliq - targetLiq;
                node.liq.mLiq -= liqDiff;
                node.liq.ncLiq -= liqDiff;
                node.liq.subtreeMLiq -= iter.width * liqDiff;
                // Now we claim the balances from the liquidity itself.
                (uint256 xOwed, uint256 yOwed) = data.computeBalances(iter.key, liqDiff, false);
                data.xBalance -= int256(xOwed);
                data.yBalance -= int256(yOwed);
            } else {
                dirty = false;
            }
        } else if (data.liq.liqType == LiqType.TAKER) {
            if (sliq < targetLiq) {
                uint128 liqDiff = targetLiq - sliq;
                node.liq.tLiq += liqDiff;
                node.liq.subtreeTLiq += iter.width * liqDiff;
                // The borrow is used to calculate payments amounts and we don't want that to fluctuate
                // with price or else the fees become too unpredictable.
                (uint256 xBorrow, uint256 yBorrow) = data.computeBorrows(iter.key, liqDiff, true);
                node.liq.subtreeBorrowedX += xBorrow;
                node.liq.subtreeBorrowedY += yBorrow;
                // But the actual balances they get are based on the current price.
                (uint256 xBalance, uint256 yBalance) = data.computeBalances(iter.key, liqDiff, false);
                data.xBalance -= int256(xBalance);
                data.yBalance -= int256(yBalance);
            } else if (sliq > targetLiq) {
                uint128 liqDiff = sliq - targetLiq;
                node.liq.tLiq -= liqDiff;
                node.liq.subtreeTLiq -= iter.width * liqDiff;
                (uint256 xBorrow, uint256 yBorrow) = data.computeBorrows(iter.key, liqDiff, true);
                node.liq.subtreeBorrowedX -= xBorrow;
                node.liq.subtreeBorrowedY -= yBorrow;
                // Takers need to return the assets to the pool according to the current proportion.
                (uint256 xBalance, uint256 yBalance) = data.computeBalances(iter.key, liqDiff, true);
                data.xBalance += int256(xBalance);
                data.yBalance += int256(yBalance);
            } else {
                dirty = false;
            }
        }
        node.liq.dirty = node.liq.dirty || dirty; // Mark the node as dirty after modification.
        aNode.sliq = targetSliq;
    }

    /// Ensure the liquidity at this node is solvent.
    /// @dev Call this after modifying liquidity.
    function solveLiq(LiqIter memory iter, Node storage node, Data memory data) internal {
        // First settle our borrows and lends from siblings and children.
        if (node.liq.preBorrow > 0) {
            node.liq.borrowed += uint128(node.liq.preBorrow);
        } else {
            node.liq.borrowed -= uint128(-node.liq.preBorrow);
        }
        node.liq.preBorrow = 0;
        if (node.liq.preLend > 0) {
            node.liq.lent += uint128(node.liq.preLend);
        } else {
            node.liq.lent -= uint128(-node.liq.preLend);
        }
        node.liq.preLend = 0;

        int128 netLiq = node.liq.net();

        if (data.isRoot(iter.key)) {
            require(netLiq >= 0, InsufficientBorrowLiquidity(netLiq));
            return;
        }

        if (netLiq == 0) {
            return;
        } else if (netLiq > 0 && node.liq.borrowed > 0) {
            // Check if we can repay liquidity.
            uint128 repayable = min(uint128(netLiq), node.liq.borrowed);
            Node storage sibling = data.node(iter.key.sibling());
            int128 sibLiq = sibling.liq.net();
            if (sibLiq <= 0 || sibling.liq.borrowed == 0) {
                // We cannot repay any borrowed liquidity.
                return;
            }
            repayable = min(repayable, uint128(sibLiq));
            repayable = min(repayable, sibling.liq.borrowed);
            if (repayable <= data.liq.compoundThreshold) {
                // Below the compound threshold it's too small to worth repaying.
                return;
            }
            Node storage parent = data.node(iter.key.parent());
            int128 iRepayable = SafeCast.toInt128(repayable);
            parent.liq.preLend -= iRepayable;
            parent.liq.dirty = true;
            node.liq.borrowed -= uint128(iRepayable);
            node.liq.dirty = true;
            sibling.liq.preBorrow -= iRepayable;
            sibling.liq.dirty = true;
        } else if (netLiq < 0) {
            // We need to borrow liquidity from our parent node.
            Node storage sibling = data.node(iter.key.sibling());
            Node storage parent = data.node(iter.key.parent());
            int128 borrow = -netLiq;
            if (borrow < int128(data.liq.compoundThreshold)) {
                // We borrow at least this amount.
                borrow = int128(data.liq.compoundThreshold);
            }
            parent.liq.preLend += borrow;
            parent.liq.dirty = true;
            node.liq.borrowed += uint128(borrow);
            node.liq.dirty = true;
            sibling.liq.preBorrow += borrow;
            sibling.liq.dirty = true;
        }
    }

    /* Helpers' Helpers */

    /// Collect non-liquidating maker fees or pay taker fees.
    /// @dev initializes the fee checks for new positions when liq is still 0. So called at the start of modify.
    function collectFees(AssetNode storage aNode, Node storage node, Data memory data) internal {
        uint128 liq = aNode.sliq;
        if (data.liq.liqType == LiqType.MAKER_NC) {
            data.xBalance -= int256(FullMath.mulX128(liq, node.fees.makerXFeesPerLiqX128 - aNode.fee0CheckX128, false));
            data.yBalance -= int256(FullMath.mulX128(liq, node.fees.makerYFeesPerLiqX128 - aNode.fee1CheckX128, false));
            aNode.fee0CheckX128 = node.fees.makerXFeesPerLiqX128;
            aNode.fee1CheckX128 = node.fees.makerYFeesPerLiqX128;
        } else if (data.liq.liqType == LiqType.TAKER) {
            // Now we pay the taker fees.
            data.xBalance += int256(FullMath.mulX128(liq, node.fees.takerXFeesPerLiqX128 - aNode.fee0CheckX128, true));
            data.yBalance += int256(FullMath.mulX128(liq, node.fees.takerYFeesPerLiqX128 - aNode.fee1CheckX128, true));
            aNode.fee0CheckX128 = node.fees.takerXFeesPerLiqX128;
            aNode.fee1CheckX128 = node.fees.takerYFeesPerLiqX128;
        }
    }

    function min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }
}
