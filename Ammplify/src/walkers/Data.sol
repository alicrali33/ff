// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Key } from "../tree/Key.sol";
import { Node } from "./Node.sol";
import { LiqData } from "./Liq.sol";
import { FeeData } from "./Fee.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolInfo, Pool, PoolLib } from "../Pool.sol";
import { Asset, AssetNode } from "../Asset.sol";
import { Store } from "../Store.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { LiqDataLib } from "./Liq.sol";
import { FeeDataLib } from "./Fee.sol";

struct Data {
    // Inputs
    address poolAddr;
    bytes32 poolStore;
    bytes32 assetStore;
    uint160 sqrtPriceX96;
    uint128 timestamp; // The last time the pool was modified.
    LiqData liq;
    FeeData fees;
    // Outputs
    int256 xBalance;
    int256 yBalance;
    /* Below are written to by walkers */
}

using DataImpl for Data global;

library DataImpl {
    error PriceSlippageExceeded(uint160 currentSqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96);

    /* Factory */
    function make(
        PoolInfo memory pInfo,
        Asset storage asset,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        uint128 liq
    ) internal returns (Data memory) {
        Pool storage pool = Store.pool(pInfo.poolAddr);
        uint128 treeTimestamp = pool.timestamp;
        pool.timestamp = uint128(block.timestamp); // Update the pool's timestamp.

        bytes32 poolSlot;
        assembly {
            poolSlot := pool.slot
        }
        bytes32 assetSlot;
        assembly {
            assetSlot := asset.slot
        }
        uint160 currentSqrtPriceX96 = PoolLib.getSqrtPriceX96(pInfo.poolAddr);
        require(
            currentSqrtPriceX96 >= minSqrtPriceX96 && currentSqrtPriceX96 <= maxSqrtPriceX96,
            PriceSlippageExceeded(currentSqrtPriceX96, minSqrtPriceX96, maxSqrtPriceX96)
        );

        return
            Data({
                poolAddr: pInfo.poolAddr,
                poolStore: poolSlot,
                assetStore: assetSlot,
                sqrtPriceX96: currentSqrtPriceX96,
                timestamp: treeTimestamp,
                liq: LiqDataLib.make(asset, pInfo, liq),
                fees: FeeDataLib.make(pInfo),
                // Outputs
                xBalance: 0,
                yBalance: 0
            });
    }

    /*
    /// TODO: currently unused but potentially used for the compound method.
    /// Used only for compounding (and testing) but the same as make.
    function makeWithoutAsset(PoolInfo memory pInfo) internal view returns (Data memory) {
        Pool storage pool = Store.pool(pInfo.poolAddr);
        uint128 treeTimestamp = pool.timestamp;

        bytes32 poolSlot;
        assembly {
            poolSlot := pool.slot
        }

        return
            Data({
                poolAddr: pInfo.poolAddr,
                poolStore: poolSlot,
                assetStore: bytes32(0),
                sqrtPriceX96: PoolLib.getSqrtPriceX96(pInfo.poolAddr),
                timestamp: treeTimestamp,
                liq: LiqDataLib.makeEmpty(),
                fees: FeeDataLib.make(pInfo),
                // Outputs
                xBalance: 0,
                yBalance: 0
            });
    } */

    function computeBorrows(
        Data memory self,
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
        Data memory self,
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

    function isRoot(Data memory self, Key key) internal pure returns (bool) {
        return key.width() == self.fees.rootWidth;
    }

    function node(Data memory self, Key key) internal view returns (Node storage) {
        Pool storage pool;
        bytes32 poolSlot = self.poolStore;
        assembly {
            pool.slot := poolSlot
        }
        return pool.nodes[key];
    }

    function assetNode(Data memory self, Key key) internal view returns (AssetNode storage) {
        Asset storage asset;
        bytes32 assetSlot = self.assetStore;
        assembly {
            asset.slot := assetSlot
        }
        return asset.nodes[key];
    }
}
