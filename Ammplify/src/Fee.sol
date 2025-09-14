// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { SmoothRateCurveConfig } from "Commons/Math/SmoothRateCurveLib.sol";
import { Store } from "./Store.sol";
import { Asset } from "./Asset.sol";
import { FullMath } from "./FullMath.sol";

struct FeeStore {
    SmoothRateCurveConfig defaultFeeCurve;
    SmoothRateCurveConfig defaultSplitCurve;
    mapping(address => SmoothRateCurveConfig) feeCurves;
    mapping(address => SmoothRateCurveConfig) splitCurves;
    mapping(address => uint128) compoundThresholds;
    uint128 defaultCompoundThreshold; // Below this amount of equivalent liq, it is not worth compounding.
    /* JIT Prevention */
    // Someone can try to use JIT to manipulate fees by supplying/removing liquidity from certain nodes
    uint64 jitLifetime; // Positions with shorter lifetimes than this will pay a penalty.
    uint64 jitPenaltyX64; // Fee paid by those who's positions are held too shortly.
    /* Collateral */
    mapping(address sender => mapping(address token => uint256)) collateral;
}

/// Makers earn fees in two ways, from the swap fees of the underlying pool
/// and the borrow fees from any open takers.
/// This just handles fees earned from takers.
library FeeLib {
    function init() internal {
        FeeStore storage store = Store.fees();
        store.defaultCompoundThreshold = 1e12; // 1 of each if both tokens are 6 decimals.
        // Target 30% at 60% util. 5% at 0%.
        store.defaultFeeCurve = SmoothRateCurveConfig({
            invAlphaX128: 102084710076281535261119195933814292480,
            betaX64: 14757395258967642112,
            maxUtilX64: 22136092888451461120, // 120%
            maxRateX64: 17524406870024073216 // 95%
        });
        // This is just for adding a super linear weight to the the split.
        // We base this around 1 to make a more even split when the difference is low.
        // E.g., the weight at 0 is ~2, 0.5 is ~3, 0.76 is ~5, 0.9 is ~10, 1 is 100.
        // @TODO The fee difference at target should be 6x that of 0% util, so
        // SmoothRateCurves probably don't work here. We should change this.
        store.defaultSplitCurve = SmoothRateCurveConfig({
            invAlphaX128: type(uint128).max, // 1
            betaX64: 36893488147419103232, // 1 (without offset)
            maxUtilX64: 18631211514446647296, // 101%
            maxRateX64: 1844674407370955161600 // 100
        });
    }

    /* Getters */

    function getCompoundThreshold(address poolAddr) internal view returns (uint128 compoundThreshold) {
        FeeStore storage store = Store.fees();
        compoundThreshold = store.compoundThresholds[poolAddr];
        if (compoundThreshold == 0) {
            compoundThreshold = store.defaultCompoundThreshold;
        }
    }

    /// Configuration for how to split fees across children subtrees.
    function getSplitCurve(address poolAddr) internal view returns (SmoothRateCurveConfig memory splitCurve) {
        FeeStore storage store = Store.fees();
        if (store.splitCurves[poolAddr].maxUtilX64 == 0) {
            return store.defaultSplitCurve;
        } else {
            return store.splitCurves[poolAddr];
        }
    }

    /// Configuration for calculating the overall fee payment averaged across all takers.
    function getRateCurve(address poolAddr) internal view returns (SmoothRateCurveConfig memory rateCurve) {
        FeeStore storage store = Store.fees();
        if (store.feeCurves[poolAddr].maxUtilX64 == 0) {
            return store.defaultFeeCurve;
        } else {
            return store.feeCurves[poolAddr];
        }
    }

    /// Applies JIT penalities to balances if applicable for this asset.
    function applyJITPenalties(
        Asset storage asset,
        uint256 xBalance,
        uint256 yBalance
    ) internal view returns (uint256 xBalanceOut, uint256 yBalanceOut) {
        FeeStore storage store = Store.fees();
        uint128 duration = uint128(block.timestamp) - asset.timestamp;
        if (duration >= store.jitLifetime) {
            return (xBalance, yBalance);
        }
        // Apply the JIT penalty.
        uint256 penaltyX64 = store.jitPenaltyX64;
        xBalanceOut = FullMath.mulX64(xBalance, penaltyX64, true);
        yBalanceOut = FullMath.mulX64(yBalance, penaltyX64, true);
    }
}
