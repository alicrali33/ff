// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { SmoothRateCurveConfig } from "Commons/Math/SmoothRateCurveLib.sol";

import { Store } from "../src/Store.sol";
import { FeeStore, FeeLib } from "../src/Fee.sol";
import { Asset } from "../src/Asset.sol";

contract FeeTest is Test {
    function setUp() public {
        FeeLib.init();
    }

    // Init

    function testInit() public view {
        FeeStore storage store = Store.fees();
        assertEq(store.defaultCompoundThreshold, 1e12);
        _assertDefaultFeeCurve(store.defaultFeeCurve);
        _assertDefaultSplitCurve(store.defaultSplitCurve);
    }

    // Getters

    function testGetCompoundThreshold() public {
        // Default
        FeeStore storage store = Store.fees();
        assertEq(FeeLib.getCompoundThreshold(address(0)), 1e12);

        // Set
        store.compoundThresholds[address(0)] = 1e13;
        assertEq(FeeLib.getCompoundThreshold(address(0)), 1e13);
    }

    function testGetSplitCurve() public {
        // Default
        _assertDefaultSplitCurve(FeeLib.getSplitCurve(address(0)));

        // Set
        FeeStore storage store = Store.fees();
        store.splitCurves[address(0)] = SmoothRateCurveConfig({
            invAlphaX128: 1,
            betaX64: 2,
            maxUtilX64: 3,
            maxRateX64: 4
        });
        SmoothRateCurveConfig memory splitCurve = FeeLib.getSplitCurve(address(0));
        assertEq(splitCurve.invAlphaX128, 1, "setSplitCurve.invAlphaX128");
        assertEq(splitCurve.betaX64, 2, "setSplitCurve.betaX64");
        assertEq(splitCurve.maxUtilX64, 3, "setSplitCurve.maxUtilX64");
        assertEq(splitCurve.maxRateX64, 4, "setSplitCurve.maxRateX64");

        // Unset
        store.splitCurves[address(0)] = SmoothRateCurveConfig({
            invAlphaX128: 1,
            betaX64: 1,
            maxUtilX64: 0, // maxUtil64 of 0 we assume the curve is not set and use the default
            maxRateX64: 1
        });
        _assertDefaultSplitCurve(FeeLib.getSplitCurve(address(0)));
    }

    function testGetRateCurve() public {
        // Default
        _assertDefaultFeeCurve(FeeLib.getRateCurve(address(0)));

        // Set
        FeeStore storage store = Store.fees();
        store.feeCurves[address(0)] = SmoothRateCurveConfig({
            invAlphaX128: 1,
            betaX64: 2,
            maxUtilX64: 3,
            maxRateX64: 4
        });
        SmoothRateCurveConfig memory rateCurve = FeeLib.getRateCurve(address(0));
        assertEq(rateCurve.invAlphaX128, 1, "setRateCurve.invAlphaX128");
        assertEq(rateCurve.betaX64, 2, "setRateCurve.betaX64");
        assertEq(rateCurve.maxUtilX64, 3, "setRateCurve.maxUtilX64");
        assertEq(rateCurve.maxRateX64, 4, "setRateCurve.maxRateX64");

        // Unset
        store.feeCurves[address(0)] = SmoothRateCurveConfig({
            invAlphaX128: 1,
            betaX64: 1,
            maxUtilX64: 0, // maxUtil64 of 0 we assume the curve is not set and use the default
            maxRateX64: 1
        });
        _assertDefaultFeeCurve(FeeLib.getRateCurve(address(0)));
    }

    // JIT

    function testApplyJITPenalties() public {
        Asset storage asset = Store.assets().assets[0];
        asset.timestamp = 200;

        FeeStore storage feeStore = Store.fees();
        feeStore.jitLifetime = 1000;
        feeStore.jitPenaltyX64 = 6148914691236516864; // 33%

        // No penalty
        vm.warp(1200);
        (uint256 xBalanceOut, uint256 yBalanceOut) = FeeLib.applyJITPenalties(asset, 100, 100);
        assertEq(xBalanceOut, 100, "noPenalty.xBalanceOut");
        assertEq(yBalanceOut, 100, "noPenalty.yBalanceOut");

        // Penalty
        vm.warp(1000);
        (xBalanceOut, yBalanceOut) = FeeLib.applyJITPenalties(asset, 100, 100);
        assertEq(xBalanceOut, 34, "penalty.xBalanceOut"); // rounds up
        assertEq(yBalanceOut, 34, "penalty.yBalanceOut"); // rounds up
    }

    // Helpers

    function _assertDefaultFeeCurve(SmoothRateCurveConfig memory rateCurve) internal pure {
        assertEq(rateCurve.invAlphaX128, 102084710076281535261119195933814292480, "defaultFeeCurve.invAlphaX128");
        assertEq(rateCurve.betaX64, 14757395258967642112, "defaultFeeCurve.betaX64");
        assertEq(rateCurve.maxUtilX64, 22136092888451461120, "defaultFeeCurve.maxUtilX64"); // 120%
        assertEq(rateCurve.maxRateX64, 17524406870024073216, "defaultFeeCurve.maxRateX64"); // 95%
    }

    function _assertDefaultSplitCurve(SmoothRateCurveConfig memory splitCurve) internal pure {
        assertEq(splitCurve.invAlphaX128, type(uint128).max, "defaultSplitCurve.invAlphaX128"); // 1
        assertEq(splitCurve.betaX64, 36893488147419103232, "defaultSplitCurve.betaX64"); // 1 (without offset)
        assertEq(splitCurve.maxUtilX64, 18631211514446647296, "defaultSplitCurve.maxUtilX64"); // 101%
        assertEq(splitCurve.maxRateX64, 1844674407370955161600, "defaultSplitCurve.maxRateX64"); // 100%
    }
}
