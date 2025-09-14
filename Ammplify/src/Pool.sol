// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { IUniswapV3PoolImmutables } from "v3-core/interfaces/pool/IUniswapV3PoolImmutables.sol";
import { IUniswapV3Pool } from "v3-core/interfaces/IUniswapV3Pool.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { FullMath } from "./FullMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { msb } from "./tree/BitMath.sol";
import { Node } from "./walkers/Node.sol";
import { Key } from "./tree/Key.sol";
import { TreeTickLib } from "./tree/Tick.sol";
import { TransientSlot } from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import { SafeCast } from "Commons/Math/Cast.sol";

// In memory struct derived from a pool
struct PoolInfo {
    address poolAddr;
    address token0;
    address token1;
    int24 tickSpacing;
    uint24 treeWidth;
}

using PoolInfoImpl for PoolInfo global;

library PoolInfoImpl {
    function tokens(PoolInfo memory self) internal pure returns (address[] memory) {
        address[] memory _tokens = new address[](2);
        _tokens[0] = self.token0;
        _tokens[1] = self.token1;
        return _tokens;
    }

    function treeTick(PoolInfo memory self, int24 tick) internal pure returns (uint24) {
        return TreeTickLib.tickToTreeIndex(tick, self.treeWidth, self.tickSpacing);
    }
}

/// Internal persistent storage bookkeeping for pools.
struct Pool {
    mapping(Key key => Node) nodes;
    // The last time the pool was modified.
    // This is ONLY updated when a new Data struct is created.
    uint128 timestamp;
}

/// A helper library for accessing the underlying pool's ABI.
/// @dev This will have to change for each pool we integrate with.
library PoolLib {
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.AddressSlot;

    // keccak256(abi.encode(uint256(keccak256("ammplify.pool.guard.20250804")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant POOL_GUARD_SLOT = 0x22683b50bc083c867d84f1a241821c03bdc9b99b2f4ba292e47bc4ea8ead2500;
    uint128 private constant X128 = type(uint128).max; // Off by 1 from x128, but will fit in 128 bits.

    function getPoolInfo(address pool) internal view returns (PoolInfo memory pInfo) {
        pInfo.poolAddr = pool;
        IUniswapV3PoolImmutables poolImmutables = IUniswapV3PoolImmutables(pool);
        pInfo.token0 = poolImmutables.token0();
        pInfo.token1 = poolImmutables.token1();

        pInfo.tickSpacing = poolImmutables.tickSpacing();
        // We find the first power of two that is less than the number of tree indices to be the width.
        pInfo.treeWidth = TreeTickLib.calcRootWidth(TickMath.MIN_TICK, TickMath.MAX_TICK, pInfo.tickSpacing);
        return pInfo;
    }

    /// Get the current sqrt price of the pool.
    function getSqrtPriceX96(address pool) internal view returns (uint160 sqrtPriceX96) {
        IUniswapV3Pool poolContract = IUniswapV3Pool(pool);
        (sqrtPriceX96, , , , , , ) = poolContract.slot0();
    }

    /*
    /// Currently unused
    /// This assumes the position in the pool still exists, and queries how much fees are owed.
    /// @dev A non-modifying way to get fees owed.
    function getFees(address pool, int24 lowerTick, int24 upperTick) internal view returns (uint128 x, uint128 y) {
        IUniswapV3Pool poolContract = IUniswapV3Pool(pool);
        bytes32 myKey = keccak256(abi.encodePacked(address(this), lowerTick, upperTick));
        uint128 liq;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // The x and y here are the fees accumulated since the last poke, before the check was updated.
        (liq, feeGrowthInside0LastX128, feeGrowthInside1LastX128, x, y) = poolContract.positions(myKey);
        (uint256 feeGrowthInside0NowX128, uint256 feeGrowthInside1NowX128) = getInsideFees(pool, lowerTick, upperTick);
        unchecked {
            x += FullMath.mulX128(liq, feeGrowthInside0NowX128 - feeGrowthInside0LastX128, false);
            y += FullMath.mulX128(liq, feeGrowthInside1NowX128 - feeGrowthInside1LastX128, false);
        }
    }
    */

    /**
     * @notice Wrapper around pool collect function.
     * Collects just fees if no liquidity has been burned, otherwise collects both.
     * @param pool to operate on
     * @param tickLower bound
     * @param tickUpper bound
     */
    function collect(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        bool burnFirst
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (burnFirst) {
            // First do an empty burn to trigger a fee calc.
            IUniswapV3Pool(pool).burn(tickLower, tickUpper, 0);
        }
        return IUniswapV3Pool(pool).collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    /// Get the fee checkpoint for a certain range. Does NOT assume the position exists.
    function getInsideFees(
        address pool,
        int24 lowerTick,
        int24 upperTick
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        IUniswapV3Pool poolContract = IUniswapV3Pool(pool);
        (, int24 currentTick, , , , , ) = poolContract.slot0();
        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = poolContract.ticks(
            lowerTick
        );
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = poolContract.ticks(
            upperTick
        );

        unchecked {
            if (currentTick < lowerTick) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (currentTick >= upperTick) {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            } else {
                uint256 feeGrowthGlobal0X128 = poolContract.feeGrowthGlobal0X128();
                uint256 feeGrowthGlobal1X128 = poolContract.feeGrowthGlobal1X128();
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        }
    }

    /// Get the liquidity specific to a particular range.
    function getLiq(address pool, int24 lowerTick, int24 upperTick) internal view returns (uint128 liq) {
        (liq, , , , ) = IUniswapV3Pool(pool).positions(
            keccak256(abi.encodePacked(address(this), lowerTick, upperTick))
        );
    }

    /**
     * @notice wrapper around pool mint function to handle callback verification
     * @param pool to operate on
     * @param tickLower bound
     * @param tickUpper bound
     * @param liquidity to mint
     */
    function mint(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal returns (uint256 amount0, uint256 amount1) {
        POOL_GUARD_SLOT.asAddress().tstore(pool);
        (amount0, amount1) = IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, "");
        POOL_GUARD_SLOT.asAddress().tstore(address(0));
    }

    /**
     * @notice wrapper around pool burn function
     * @param pool to operate on
     * @param tickLower bound
     * @param tickUpper bound
     * @param liquidity to burn
     */
    function burn(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal returns (uint256 amount0, uint256 amount1) {
        return IUniswapV3Pool(pool).burn(tickLower, tickUpper, liquidity);
    }

    function poolGuard() internal view returns (address) {
        return POOL_GUARD_SLOT.asAddress().tload();
    }

    /// Answers how much liquidity we can add from the given amounts for the given range, and
    /// how much is leftover.
    /// @dev Rounds liq down.
    function getAssignableLiq(
        int24 lowTick,
        int24 highTick,
        uint128 x,
        uint128 y,
        uint160 sqrtPriceX96
    ) internal pure returns (uint128 assignableLiq, uint128 leftoverX, uint128 leftoverY) {
        uint160 lowSqrtPriceX96 = TickMath.getSqrtPriceAtTick(lowTick);
        uint160 highSqrtPriceX96 = TickMath.getSqrtPriceAtTick(highTick);

        if (sqrtPriceX96 <= lowSqrtPriceX96) {
            // We are below the range, so we can only add liquidity for token0.
            leftoverY = y;
            if (x == 0) {
                return (0, leftoverX, leftoverY);
            }
            // Round up to round liq down.
            uint256 unitX128 = SqrtPriceMath.getAmount0Delta(lowSqrtPriceX96, highSqrtPriceX96, X128, true);
            assignableLiq = uint128((uint256(x) * X128) / unitX128);
            // No leftover x, perhaps lose x dust here but it's okay.
        } else if (sqrtPriceX96 >= highSqrtPriceX96) {
            // We are above the range, so we can only add liquidity for token1.
            leftoverX = x;
            if (y == 0) {
                return (0, leftoverX, leftoverY);
            }
            // Round up to round liq down.
            uint256 unitX128 = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, highSqrtPriceX96, X128, true);
            assignableLiq = uint128((uint256(y) * X128) / unitX128);
            // No leftover y, perhaps lose y dust here but it's okay.
        } else {
            uint256 reqXUnitX128 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, highSqrtPriceX96, X128, true);
            uint256 reqYUnitX128 = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, sqrtPriceX96, X128, true);
            uint256 xLiq = (uint256(x) * X128) / reqXUnitX128;
            uint256 yLiq = (uint256(y) * X128) / reqYUnitX128;
            if (xLiq == yLiq) {
                assignableLiq = uint128(xLiq);
            } else if (xLiq < yLiq) {
                assignableLiq = uint128(xLiq);
                leftoverY = y - uint128(FullMath.mulX128(xLiq, reqYUnitX128, true));
            } else {
                assignableLiq = uint128(yLiq);
                leftoverX = x - uint128(FullMath.mulX128(yLiq, reqXUnitX128, true));
            }
        }
    }

    // How much liquidity is are these assets worth in the given range.
    function getEquivalentLiq(
        int24 lowTick,
        int24 highTick,
        uint256 x,
        uint256 y,
        uint160 sqrtPriceX96,
        bool roundUp
    ) internal pure returns (uint128 equivLiq) {
        (uint256 lxX128, uint256 lyX128) = getAmounts(sqrtPriceX96, lowTick, highTick, X128, roundUp);
        uint256 liqValueX128 = (FullMath.mulX64(lxX128, sqrtPriceX96, false) >> 32) + (lyX128 << 96) / sqrtPriceX96;
        uint256 myValue = FullMath.mulX128(x, uint256(sqrtPriceX96) << 32, false) + (y << 96) / sqrtPriceX96;
        if (roundUp) {
            equivLiq = SafeCast.toUint128(FullMath.mulDivRoundingUp(myValue, X128, liqValueX128));
        } else {
            equivLiq = SafeCast.toUint128(FullMath.mulDiv(myValue, X128, liqValueX128));
        }
    }

    /// Get the amounts of each token for the liquidity in the given range.
    function getAmounts(
        uint160 sqrtPriceX96,
        int24 lowTick,
        int24 highTick,
        uint128 liq,
        bool roundUp
    ) internal pure returns (uint256 x, uint256 y) {
        if (liq == 0) {
            return (0, 0);
        }

        uint160 lowSqrtPriceX96 = TickMath.getSqrtPriceAtTick(lowTick);
        uint160 highSqrtPriceX96 = TickMath.getSqrtPriceAtTick(highTick);

        if (sqrtPriceX96 < lowSqrtPriceX96) {
            // We are below the range, so we can only get token0.
            x = SqrtPriceMath.getAmount0Delta(lowSqrtPriceX96, highSqrtPriceX96, liq, roundUp);
            y = 0;
        } else if (sqrtPriceX96 >= highSqrtPriceX96) {
            // We are above the range, so we can only get token1.
            x = 0;
            y = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, highSqrtPriceX96, liq, roundUp);
        } else {
            // We are in the range, so we can get both tokens.
            x = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, highSqrtPriceX96, liq, roundUp);
            y = SqrtPriceMath.getAmount1Delta(lowSqrtPriceX96, sqrtPriceX96, liq, roundUp);
        }
    }
}
