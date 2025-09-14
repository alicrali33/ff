// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { IUniswapV3Pool } from "v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { TransferHelper } from "Commons/Util/TransferHelper.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { LiquidityAmounts } from "./utils/LiquidityAmounts.sol";
import { SafeCast } from "Commons/Math/Cast.sol";
import { UniV3IntegrationSetup } from "./UniV3.u.sol";
import { PoolLib, PoolInfo, PoolInfoImpl } from "../src/Pool.sol";

contract PoolInfoImplTest is Test {
    function testTokens() public pure {
        PoolInfo memory pInfo;
        pInfo.token0 = address(0x0);
        pInfo.token1 = address(0x1);

        address[] memory tokens = PoolInfoImpl.tokens(pInfo);
        assertEq(tokens[0], address(0x0));
        assertEq(tokens[1], address(0x1));
    }
}

contract PoolTest is Test, UniV3IntegrationSetup {
    address poolAddr;
    IUniswapV3Pool pool;
    bool bypassPoolGuardAssert;

    function setUp() public {
        setUpPool();

        poolAddr = pools[0];
        pool = IUniswapV3Pool(poolAddr);
    }

    function testGetPoolInfo() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(poolAddr);
        assertEq(pInfo.poolAddr, poolAddr);
        assertEq(pInfo.token0, pool.token0());
        assertEq(pInfo.token1, pool.token1());
        assertEq(pInfo.tickSpacing, pool.tickSpacing());
        assertEq(pInfo.tickSpacing, 60, "tickSpacing.fee.3000");
        assertEq(pInfo.treeWidth, 2 ** 14, "treeWidth.fee.3000");

        setUpPool(500);
        pInfo = PoolLib.getPoolInfo(pools[1]);
        assertEq(pInfo.tickSpacing, 10, "tickSpacing.fee.500");
        assertEq(pInfo.treeWidth, 2 ** 17, "treeWidth.fee.500");

        setUpPool(10000);
        pInfo = PoolLib.getPoolInfo(pools[2]);
        assertEq(pInfo.tickSpacing, 200, "tickSpacing.fee.10000");
        assertEq(pInfo.treeWidth, 2 ** 13, "treeWidth.fee.10000");
    }

    function testGetSqrtPriceX96() public {
        (uint160 slot0SqrtPriceX96, int24 slot0Tick, , , , , ) = pool.slot0();
        assertEq(slot0SqrtPriceX96, PoolLib.getSqrtPriceX96(poolAddr));

        uint160 currentTickSqrtPriceX96 = TickMath.getSqrtPriceAtTick(slot0Tick);
        uint160 nextTickSqrtPriceX96 = TickMath.getSqrtPriceAtTick(slot0Tick + pool.tickSpacing());
        uint160 middleSqrtPriceX96 = currentTickSqrtPriceX96 + (nextTickSqrtPriceX96 - currentTickSqrtPriceX96) / 2;

        // verify assumptions
        assertLt(currentTickSqrtPriceX96, nextTickSqrtPriceX96);
        assertLt(middleSqrtPriceX96, nextTickSqrtPriceX96);
        assertGt(middleSqrtPriceX96, currentTickSqrtPriceX96);

        // swap to price between ticks
        swapTo(0, middleSqrtPriceX96);

        // verify reported sqrt price is between ticks
        (slot0SqrtPriceX96, , , , , , ) = pool.slot0();
        assertEq(slot0SqrtPriceX96, PoolLib.getSqrtPriceX96(poolAddr));
        assertEq(slot0SqrtPriceX96, middleSqrtPriceX96);
    }

    function testGetLiq() public {
        // Position 1
        int24 tickLower = pool.tickSpacing() * -10;
        int24 tickUpper = pool.tickSpacing() * 10;

        uint128 liq = PoolLib.getLiq(poolAddr, tickLower, tickUpper);
        assertEq(liq, 0, "liq.position1.noLiq");

        PoolLib.mint(poolAddr, tickLower, tickUpper, 1e20);
        liq = PoolLib.getLiq(poolAddr, tickLower, tickUpper);
        assertEq(liq, 1e20, "liq.position1.mint1");

        PoolLib.mint(poolAddr, tickLower, tickUpper, 2e20);
        liq = PoolLib.getLiq(poolAddr, tickLower, tickUpper);
        assertEq(liq, 3e20, "liq.position1.mint2");

        // Position 1
        tickUpper = pool.tickSpacing() * 20;

        liq = PoolLib.getLiq(poolAddr, tickLower, tickUpper);
        assertEq(liq, 0, "liq.position2.noLiq");

        PoolLib.mint(poolAddr, tickLower, tickUpper, 1e5);
        liq = PoolLib.getLiq(poolAddr, tickLower, tickUpper);
        assertEq(liq, 1e5, "liq.position2.mint1");
    }

    function testMint() public {
        int24 tickSpacing = pool.tickSpacing();
        int24 tickLower = tickSpacing * -10;
        int24 tickUpper = tickSpacing * 10;
        uint128 liq = 1e20;

        uint256 balance0 = IERC20(pool.token0()).balanceOf(address(this));
        uint256 balance1 = IERC20(pool.token1()).balanceOf(address(this));

        bypassPoolGuardAssert = true;
        (uint256 directMint0, uint256 directMint1) = pool.mint(address(this), tickLower, tickUpper, liq, "");
        bypassPoolGuardAssert = false;

        vm.expectCall(poolAddr, abi.encodeCall(pool.mint, (address(this), tickLower, tickUpper, liq, "")));
        (uint256 mint0, uint256 mint1) = PoolLib.mint(poolAddr, tickLower, tickUpper, liq);

        assertEq(mint0, directMint0, "mint0");
        assertEq(mint1, directMint1, "mint1");

        assertEq(balance0 - directMint0 - mint0, IERC20(pool.token0()).balanceOf(address(this)), "recieved.token0");
        assertEq(balance1 - directMint1 - mint1, IERC20(pool.token1()).balanceOf(address(this)), "recieved.token1");
    }

    function testBurn() public {
        int24 tickSpacing = pool.tickSpacing();
        int24 tickLower = tickSpacing * -10;
        int24 tickUpper = tickSpacing * 10;
        uint128 liq = 1e20;

        (uint256 mint0, uint256 mint1) = PoolLib.mint(poolAddr, tickLower, tickUpper, liq);

        vm.expectCall(poolAddr, abi.encodeCall(pool.burn, (tickLower, tickUpper, liq)));
        (uint256 burn0, uint256 burn1) = PoolLib.burn(poolAddr, tickLower, tickUpper, liq);

        assertApproxEqAbs(mint0, burn0, 1, "mint0.equals.burn0");
        assertApproxEqAbs(mint1, burn1, 1, "mint1.equals.burn1");
    }

    function testCollect() public {
        int24 tickSpacing = pool.tickSpacing();
        int24 tickLower = tickSpacing * -10;
        int24 tickUpper = tickSpacing * 10;
        uint128 liq = 1e20;

        PoolLib.mint(poolAddr, tickLower, tickUpper, liq);
        (uint256 burn0, uint256 burn1) = PoolLib.burn(poolAddr, tickLower, tickUpper, liq);

        uint256 balance0 = IERC20(pool.token0()).balanceOf(address(this));
        uint256 balance1 = IERC20(pool.token1()).balanceOf(address(this));

        vm.expectCall(
            poolAddr,
            abi.encodeCall(pool.collect, (address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max))
        );
        (uint256 collect0, uint256 collect1) = PoolLib.collect(poolAddr, tickLower, tickUpper, false);

        assertEq(collect0, burn0, "collect0.equals.burn0");
        assertEq(collect1, burn1, "collect1.equals.burn1");

        assertEq(balance0 + collect0, IERC20(pool.token0()).balanceOf(address(this)), "recieved.token0");
        assertEq(balance1 + collect1, IERC20(pool.token1()).balanceOf(address(this)), "recieved.token1");
    }

    function testGetInsideFees() public {
        int24 tickSpacing = pool.tickSpacing();
        bypassPoolGuardAssert = true;
        addPoolLiq(0, tickSpacing * -1000, tickSpacing * 1000, 1e20);
        bypassPoolGuardAssert = false;

        // verify starting tick is 0
        (, int24 currentTick, , , , , ) = pool.slot0();
        assertEq(currentTick, 0, "currentTick.equals.0");

        // create position
        int24 tickLower = tickSpacing * -10;
        int24 tickUpper = tickSpacing * 10;
        uint128 liq = 1e20;

        PoolLib.mint(poolAddr, tickLower, tickUpper, liq);

        // verify fees are 0
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = PoolLib.getInsideFees(
            poolAddr,
            tickLower,
            tickUpper
        );
        assertEq(feeGrowthInside0X128, 0, "feeGrowthInside0X128.equals.0");
        assertEq(feeGrowthInside1X128, 0, "feeGrowthInside1X128.equals.0");

        // swap below range
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower - (tickSpacing * 10)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower - (tickSpacing * 100)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower - (tickSpacing * 20)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower - (tickSpacing * 1)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower - (tickSpacing * 50)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower - (tickSpacing * 100)));

        // swap above range
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper + (tickSpacing * 10)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper + (tickSpacing * 20)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper + (tickSpacing * 100)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper + (tickSpacing * 200)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper + (tickSpacing * 50)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper + (tickSpacing * 30)));

        // swap inrange
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower + (tickSpacing * 5)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower + (tickSpacing * 2)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower + (tickSpacing * 7)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower + (tickSpacing * 1)));
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper - (tickSpacing * 2)));

        // move price below range
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower - (tickSpacing * 10)));
        (, currentTick, , , , , ) = pool.slot0();
        assertLt(currentTick, tickLower, "currentTick.lt.tickLower");

        PoolLib.mint(poolAddr, tickLower, tickUpper, 1); // accumulate fees
        (feeGrowthInside0X128, feeGrowthInside1X128) = PoolLib.getInsideFees(poolAddr, tickLower, tickUpper);
        (, uint256 posFeeGrowthInside0X128, uint256 posFeeGrowthInside1X128, , ) = pool.positions(
            keccak256(abi.encodePacked(address(this), tickLower, tickUpper))
        );
        assertEq(
            feeGrowthInside0X128,
            posFeeGrowthInside0X128,
            "feeGrowthInside0X128.equals.posFeeGrowthInside0X128.belowRange"
        );
        assertEq(
            feeGrowthInside1X128,
            posFeeGrowthInside1X128,
            "feeGrowthInside1X128.equals.posFeeGrowthInside1X128.belowRange"
        );
        assertGt(posFeeGrowthInside0X128, 0, "posFeeGrowthInside0X128.gt.0");
        assertGt(posFeeGrowthInside1X128, 0, "posFeeGrowthInside1X128.gt.0");

        // move price above range
        swapTo(0, TickMath.getSqrtPriceAtTick(tickUpper + (tickSpacing * 10)));
        (, currentTick, , , , , ) = pool.slot0();
        assertGt(currentTick, tickUpper, "currentTick.gt.tickUpper");

        PoolLib.mint(poolAddr, tickLower, tickUpper, 1); // accumulate fees
        (feeGrowthInside0X128, feeGrowthInside1X128) = PoolLib.getInsideFees(poolAddr, tickLower, tickUpper);
        (, posFeeGrowthInside0X128, posFeeGrowthInside1X128, , ) = pool.positions(
            keccak256(abi.encodePacked(address(this), tickLower, tickUpper))
        );
        assertEq(
            feeGrowthInside0X128,
            posFeeGrowthInside0X128,
            "feeGrowthInside0X128.equals.posFeeGrowthInside0X128.aboveRange"
        );
        assertEq(
            feeGrowthInside1X128,
            posFeeGrowthInside1X128,
            "feeGrowthInside1X128.equals.posFeeGrowthInside1X128.aboveRange"
        );
        assertGt(posFeeGrowthInside0X128, 0, "posFeeGrowthInside0X128.gt.0");
        assertGt(posFeeGrowthInside1X128, 0, "posFeeGrowthInside1X128.gt.0");

        // move price in range
        swapTo(0, TickMath.getSqrtPriceAtTick(tickLower + (tickSpacing * 5)));
        (, currentTick, , , , , ) = pool.slot0();
        assertLt(currentTick, tickUpper, "currentTick.lt.tickUpper");
        assertGt(currentTick, tickLower, "currentTick.gt.tickLower");

        PoolLib.mint(poolAddr, tickLower, tickUpper, 1); // accumulate fees
        (feeGrowthInside0X128, feeGrowthInside1X128) = PoolLib.getInsideFees(poolAddr, tickLower, tickUpper);
        (, posFeeGrowthInside0X128, posFeeGrowthInside1X128, , ) = pool.positions(
            keccak256(abi.encodePacked(address(this), tickLower, tickUpper))
        );
        assertEq(
            feeGrowthInside0X128,
            posFeeGrowthInside0X128,
            "feeGrowthInside0X128.equals.posFeeGrowthInside0X128.inRange"
        );
        assertEq(
            feeGrowthInside1X128,
            posFeeGrowthInside1X128,
            "feeGrowthInside1X128.equals.posFeeGrowthInside1X128.inRange"
        );
        assertGt(posFeeGrowthInside0X128, 0, "posFeeGrowthInside0X128.gt.0");
        assertGt(posFeeGrowthInside1X128, 0, "posFeeGrowthInside1X128.gt.0");
    }

    // Assignable Liq

    function testGetAssignableLiqBelowRange() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-3000);
        uint128 x = 200e18;
        uint128 y = 100e6;

        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            lowTick,
            highTick,
            x,
            y,
            sqrtPriceX96
        );

        uint128 expectedLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );
        (uint256 usedX, uint256 usedY) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            expectedLiq
        );

        assertEq(assignableLiq, expectedLiq, "assignableLiq.equals.expectedLiq");
        assertApproxEqAbs(leftoverX, x - uint128(usedX), 1, "leftoverX.equals.x.minus.usedX"); // 1 x lost to dust
        assertEq(leftoverX, 0, "leftoverX.equals.0");
        assertEq(leftoverY, y - uint128(usedY), "leftoverY.equals.y.minus.usedY");
    }

    function testGetAssignableLiqBelowRangeZeroX() public pure {
        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            -2000,
            2000,
            0,
            100e6,
            TickMath.getSqrtPriceAtTick(-3000)
        );
        assertEq(assignableLiq, 0, "assignableLiq.equals.0");
        assertEq(leftoverX, 0, "leftoverX.equals.0");
        assertEq(leftoverY, 100e6, "leftoverY.equals.y");
    }

    // verify we can pass max values w/o overflowing
    function testGetAssignableLiqBelowRangeOverflowCheck() public pure {
        PoolLib.getAssignableLiq(
            TickMath.MIN_TICK + 1,
            TickMath.MAX_TICK,
            type(uint128).max,
            type(uint128).max,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK)
        );
        PoolLib.getAssignableLiq(0, 1, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(-1));
    }

    function testGetAssignableLiqAboveRange() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(3000);
        uint128 x = 200e18;
        uint128 y = 100e6;

        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            lowTick,
            highTick,
            x,
            y,
            sqrtPriceX96
        );

        uint128 expectedLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );
        (uint256 usedX, uint256 usedY) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            expectedLiq
        );

        assertEq(assignableLiq, expectedLiq, "assignableLiq.equals.expectedLiq");
        assertEq(leftoverX, x - uint128(usedX), "leftoverX.equals.x.minus.usedX");
        assertApproxEqAbs(leftoverY, y - uint128(usedY), 1, "leftoverY.equals.y.minus.usedY"); // 1 y lost to dust
        assertEq(leftoverY, 0, "leftoverY.equals.0");
    }

    function testGetAssignableLiqAboveRangeZeroY() public pure {
        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            -2000,
            2000,
            200e18,
            0,
            TickMath.getSqrtPriceAtTick(3000)
        );
        assertEq(assignableLiq, 0, "assignableLiq.equals.0");
        assertEq(leftoverX, 200e18, "leftoverX.equals.x");
        assertEq(leftoverY, 0, "leftoverY.equals.0");
    }

    // verify we can pass max values w/o overflowing
    function testGetAssignableLiqAboveRangeOverflowCheck() public pure {
        PoolLib.getAssignableLiq(
            TickMath.MIN_TICK,
            TickMath.MAX_TICK,
            type(uint128).max,
            type(uint128).max,
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK)
        );
        PoolLib.getAssignableLiq(0, 1, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(2));
    }

    function testGetAssignableLiqInRangeXLiqEqualsYLiq() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint128 x = 200e18;
        uint128 y = 200e18;

        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            lowTick,
            highTick,
            x,
            y,
            sqrtPriceX96
        );

        uint128 expectedLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );
        (uint256 usedX, uint256 usedY) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            expectedLiq
        );

        assertEq(assignableLiq, expectedLiq, "assignableLiq.equals.expectedLiq");
        assertApproxEqAbs(leftoverX, x - uint128(usedX), 1, "leftoverX.equals.x.minus.usedX");
        assertLt(leftoverX, x - uint128(usedX), "leftoverX.lt.x.minus.usedX");
        assertApproxEqAbs(leftoverY, y - uint128(usedY), 1, "leftoverY.equals.y.minus.usedY");
        assertLt(leftoverY, y - uint128(usedY), "leftoverY.lt.y.minus.usedY");
    }

    function testGetAssignableLiqInRangeXLiqLessThanYLiq() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint128 x = 100e6;
        uint128 y = 200e18;

        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            lowTick,
            highTick,
            x,
            y,
            sqrtPriceX96
        );

        uint128 expectedLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );
        (uint256 usedX, uint256 usedY) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            expectedLiq
        );

        assertEq(assignableLiq, expectedLiq, "assignableLiq.equals.expectedLiq");
        assertApproxEqAbs(leftoverX, x - uint128(usedX), 1, "leftoverX.equals.x.minus.usedX");
        assertLt(leftoverX, x - uint128(usedX), "leftoverX.lt.x.minus.usedX");
        assertApproxEqAbs(leftoverY, y - uint128(usedY), 1, "leftoverY.equals.y.minus.usedY");
        assertLt(leftoverY, y - uint128(usedY), "leftoverY.lt.y.minus.usedY");
    }

    function testGetAssignableLiqInRangeXLiqGreaterThanYLiq() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint128 x = 200e18;
        uint128 y = 100e6;

        (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) = PoolLib.getAssignableLiq(
            lowTick,
            highTick,
            x,
            y,
            sqrtPriceX96
        );

        uint128 expectedLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );
        (uint256 usedX, uint256 usedY) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            expectedLiq
        );

        assertEq(assignableLiq, expectedLiq, "assignableLiq.equals.expectedLiq");
        assertApproxEqAbs(leftoverX, x - uint128(usedX), 1, "leftoverX.equals.x.minus.usedX");
        assertLt(leftoverX, x - uint128(usedX), "leftoverX.lt.x.minus.usedX");
        assertApproxEqAbs(leftoverY, y - uint128(usedY), 1, "leftoverY.equals.y.minus.usedY");
        assertLt(leftoverY, y - uint128(usedY), "leftoverY.lt.y.minus.usedY");
    }

    // verify we can pass max values w/o overflowing
    function testGetAssignableLiqInRangeOverflowCheckXLiqLessThanYLiq() public pure {
        PoolLib.getAssignableLiq(-10, 10, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(-3));
    }

    // verify we can pass max values w/o overflowing
    function testGetAssignableLiqInRangeOverflowCheckXLiqGreaterThanYLiq() public pure {
        PoolLib.getAssignableLiq(-10, 10, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(3));
    }

    // verify we can pass max values w/o overflowing
    function testGetAssignableLiqInRangeOverflowCheckXLiqEqualsYLiq() public pure {
        // note: difficult to hit xLiq == yLiq with larger values for x and y
        // hover logic in the other two cases covers logic in this case sufficiently
        PoolLib.getAssignableLiq(-10, 10, 1e21, 1e21, TickMath.getSqrtPriceAtTick(0));
    }

    // Equivalent Liq

    // TODO: double check conversion
    function testGetEquivalentLiqBelowRangeConvertingY() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-3000);
        uint128 x = 200e18;
        uint128 y = 200e18;

        uint128 equivLiqRoundingDown = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, false);
        uint128 equivLiqRoundingUp = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, true);

        assertEq(equivLiqRoundingDown, 2346044413003865165004, "equivLiqRoundingDown");
        assertEq(equivLiqRoundingUp, 2346044413003865165005, "equivLiqRoundingUp");
    }

    function testGetEquivalentLiqBelowRangeNoY() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-3000);
        uint128 x = 200e18;
        uint128 y = 0;

        uint128 equivLiqRoundingDown = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, false);
        uint128 equivLiqRoundingUp = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, true);

        uint128 actualLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );

        assertApproxEqAbs(
            equivLiqRoundingDown,
            equivLiqRoundingUp,
            1,
            "equivLiqRoundingDown.equals.equivLiqRoundingUp"
        );
        assertLt(equivLiqRoundingDown, equivLiqRoundingUp, "equivLiqRoundingDown.lt.equivLiqRoundingUp");
        assertEq(equivLiqRoundingUp, actualLiq, "equivLiqRoundingUp.equals.actualLiq");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertGetEquivalentLiqBelowRangeLiqOverMaxRoundingDown() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.UnsafeUCast.selector,
                13612996131207439090653226566178355568195406,
                type(uint128).max
            )
        );
        PoolLib.getEquivalentLiq(0, 1, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(-1), false);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertGetEquivalentLiqBelowRangeLiqOverMaxRoundingUp() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.UnsafeUCast.selector,
                13612996131207439090653226566178354767995391,
                type(uint128).max
            )
        );
        PoolLib.getEquivalentLiq(0, 1, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(-1), true);
    }

    // TODO: double check conversion
    function testGetEquivalentLiqAboveRangeConvertingX() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(3000);
        uint128 x = 200e18;
        uint128 y = 200e18;

        uint128 equivLiqRoundingDown = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, false);
        uint128 equivLiqRoundingUp = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, true);

        assertEq(equivLiqRoundingDown, 2346044413003865165004, "equivLiqRoundingDown");
        assertEq(equivLiqRoundingUp, 2346044413003865165005, "equivLiqRoundingUp");
    }

    function testGetEquivalentLiqAboveRangeNoX() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(3000);
        uint128 x = 0;
        uint128 y = 200e18;

        uint128 equivLiqRoundingDown = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, false);
        uint128 equivLiqRoundingUp = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, true);

        uint128 actualLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );

        // TODO: why is roundingUp equal to actualLiq?
        assertApproxEqAbs(
            equivLiqRoundingDown,
            equivLiqRoundingUp,
            1,
            "equivLiqRoundingDown.equals.equivLiqRoundingUp"
        );
        assertLt(equivLiqRoundingDown, equivLiqRoundingUp, "equivLiqRoundingDown.lt.equivLiqRoundingUp");
        assertEq(equivLiqRoundingUp, actualLiq, "equivLiqRoundingUp.equals.actualLiq");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertGetEquivalentLiqAboveRangeLiqOverMaxRoundingDown() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.UnsafeUCast.selector,
                13612996182251070166403099169497108467528216,
                type(uint128).max
            )
        );
        PoolLib.getEquivalentLiq(0, 1, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(2), false);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertGetEquivalentLiqAboveRangeLiqOverMaxRoundingUp() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.UnsafeUCast.selector,
                13612996182251070166403099169497107667328197,
                type(uint128).max
            )
        );
        PoolLib.getEquivalentLiq(0, 1, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(2), true);
    }

    function testGetEquivalentLiqInRangeNoConversion() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint128 x = 200e18;
        uint128 y = 200e18;

        uint128 equivLiqRoundingDown = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, false);
        uint128 equivLiqRoundingUp = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, true);

        uint128 actualLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lowTick),
            TickMath.getSqrtPriceAtTick(highTick),
            uint256(x),
            uint256(y)
        );

        assertApproxEqAbs(
            equivLiqRoundingDown,
            equivLiqRoundingUp,
            1,
            "equivLiqRoundingDown.equals.equivLiqRoundingUp"
        );
        assertLt(equivLiqRoundingDown, equivLiqRoundingUp, "equivLiqRoundingDown.lt.equivLiqRoundingUp");
        assertEq(equivLiqRoundingDown, actualLiq, "equivLiqRoundingDown.equals.actualLiq");
    }

    // TODO: double check conversion
    function testGetEquivalentLiqInRangeConvertingX() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(1000);
        uint128 x = 200e18;
        uint128 y = 200e18;

        uint128 equivLiqRoundingDown = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, false);
        uint128 equivLiqRoundingUp = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, true);

        assertEq(equivLiqRoundingDown, 2129710359649553392551, "equivLiqRoundingDown");
        assertEq(equivLiqRoundingUp, 2129710359649553392552, "equivLiqRoundingUp");
    }

    // TODO: double check conversion
    function testGetEquivalentLiqInRangeConvertingY() public pure {
        int24 lowTick = -2000;
        int24 highTick = 2000;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-1000);
        uint128 x = 200e18;
        uint128 y = 200e18;

        uint128 equivLiqRoundingDown = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, false);
        uint128 equivLiqRoundingUp = PoolLib.getEquivalentLiq(lowTick, highTick, x, y, sqrtPriceX96, true);

        assertEq(equivLiqRoundingDown, 2129710359649553392551, "equivLiqRoundingDown");
        assertEq(equivLiqRoundingUp, 2129710359649553392552, "equivLiqRoundingUp");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertGetEquivalentLiqInRangeLiqOverMaxRoundingDown() public {
        // Rounding down
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.UnsafeUCast.selector,
                680768916872643588502673340623806917354623,
                type(uint128).max
            )
        );
        PoolLib.getEquivalentLiq(-10, 10, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(0), false);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertGetEquivalentLiqInRangeLiqOverMaxRoundingUp() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.UnsafeUCast.selector,
                680768916872643588502673340623806913352223,
                type(uint128).max
            )
        );
        PoolLib.getEquivalentLiq(-10, 10, type(uint128).max, type(uint128).max, TickMath.getSqrtPriceAtTick(0), true);
    }

    // Get Amounts

    function testGetAmounts() public pure {
        // No liq
        (uint256 x, uint256 y) = PoolLib.getAmounts(0, 0, 0, 0, false);
        assertEq(x, 0, "x.noLiq");
        assertEq(y, 0, "y.noLiq");

        int24 lowTick = -2000;
        int24 highTick = 2000;

        uint160 sqrtPriceX96;
        uint160 lowSqrtPriceX96 = TickMath.getSqrtPriceAtTick(lowTick);
        uint160 highSqrtPriceX96 = TickMath.getSqrtPriceAtTick(highTick);

        uint256 expectedXRoundingDown;
        uint256 expectedXRoundingUp;
        uint256 expectedYRoundingDown;
        uint256 expectedYRoundingUp;

        uint128 liq = 1000000000000000000;

        // Price below range
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(lowTick - 2000);

        expectedXRoundingDown = SqrtPriceMath.getAmount0Delta(lowSqrtPriceX96, highSqrtPriceX96, liq, false);
        expectedXRoundingUp = SqrtPriceMath.getAmount0Delta(lowSqrtPriceX96, highSqrtPriceX96, liq, true);

        assertNotEq(expectedXRoundingDown, expectedXRoundingUp, "x.belowRange.roundingDirection.notEqual");

        (x, y) = PoolLib.getAmounts(sqrtPriceX96, lowTick, highTick, liq, false);
        assertEq(x, expectedXRoundingDown, "x.belowRange.roundingDown");
        assertEq(y, 0, "y.belowRange.roundingDown");

        (x, y) = PoolLib.getAmounts(sqrtPriceX96, lowTick, highTick, liq, true);
        assertEq(x, expectedXRoundingUp, "x.belowRange.roundingUp");
        assertEq(y, 0, "y.belowRange.roundingUp");

        // Price above range
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(highTick + 2000);

        expectedYRoundingDown = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, highSqrtPriceX96, liq, false);
        expectedYRoundingUp = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, highSqrtPriceX96, liq, true);

        (x, y) = PoolLib.getAmounts(sqrtPriceX96, lowTick, highTick, liq, false);
        (x, y) = PoolLib.getAmounts(sqrtPriceX96, lowTick, highTick, liq, false);
        assertEq(x, 0, "x.aboveRange.roundingDown");
        assertEq(y, expectedYRoundingDown, "y.aboveRange.roundingDown");

        (x, y) = PoolLib.getAmounts(sqrtPriceX96, lowTick, highTick, liq, true);
        assertEq(x, 0, "x.aboveRange.roundingUp");
        assertEq(y, expectedYRoundingUp, "y.aboveRange.roundingUp");

        // Price in range
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(lowTick + (highTick - lowTick) / 2);

        expectedXRoundingDown = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, highSqrtPriceX96, liq, false);
        expectedXRoundingUp = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, highSqrtPriceX96, liq, true);
        expectedYRoundingDown = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, sqrtPriceX96, liq, false);
        expectedYRoundingUp = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, sqrtPriceX96, liq, true);

        (x, y) = PoolLib.getAmounts(sqrtPriceX96, lowTick, highTick, liq, false);
        assertEq(x, expectedXRoundingDown, "x.inRange.roundingDown");
        assertEq(y, expectedYRoundingDown, "y.inRange.roundingDown");

        (x, y) = PoolLib.getAmounts(sqrtPriceX96, lowTick, highTick, liq, true);
        assertEq(x, expectedXRoundingUp, "x.inRange.roundingUp");
        assertEq(y, expectedYRoundingUp, "y.inRange.roundingUp");
    }

    // Mint Callback

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
        if (!bypassPoolGuardAssert) {
            assertEq(PoolLib.poolGuard(), msg.sender, "poolGuard.mintCallback");
        }

        TransferHelper.safeTransfer(pool.token0(), msg.sender, amount0Owed);
        TransferHelper.safeTransfer(pool.token1(), msg.sender, amount1Owed);
    }
}
