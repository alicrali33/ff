// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import { IERC20 } from "Commons/ERC/interfaces/IERC20.sol";
import { ForkableTest } from "Commons/Test/ForkableTest.sol";
import { IUniswapV3Pool } from "v3-core/interfaces/IUniswapV3Pool.sol";

import { SimplexDiamond } from "../../src/Diamond.sol";
import { UniV3Decomposer } from "../../src/integrations/UniV3Decomposer.sol";
import {
    INonfungiblePositionManager
} from "../../src/integrations/univ3-periphery/interfaces/INonfungiblePositionManager.sol";

/**
 * @title AmmplifyForkBase
 * @notice Base contract for fork testing Uniswap V3 with Ammplify
 * @dev Extends ForkableTest to provide Uniswap V3 specific helper functions
 */
contract AmmplifyForkBase is ForkableTest {
    // Uniswap V3 contracts
    INonfungiblePositionManager public nftManager;
    IUniswapV3Pool public pool;

    // Ammplify contracts
    SimplexDiamond public diamond;

    // Helper contracts
    UniV3Decomposer public decomposer;

    // Test tokens
    IERC20 public token0;
    IERC20 public token1;

    // Position tracking
    uint256 public nextTokenId = 1;
    mapping(uint256 => PositionInfo) public positions;

    struct PositionInfo {
        address owner;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
    }

    // Constants for common fee tiers
    uint24 public constant FEE_TIER_500 = 500; // 0.05%
    uint24 public constant FEE_TIER_3000 = 3000; // 0.3%
    uint24 public constant FEE_TIER_10000 = 10000; // 1%

    // Common tick ranges
    int24 public constant TICK_SPACING_500 = 10;
    int24 public constant TICK_SPACING_3000 = 60;
    int24 public constant TICK_SPACING_10000 = 200;

    function forkSetup() internal virtual override {
        // Load addresses from fork JSON
        nftManager = INonfungiblePositionManager(getAddr("NFT_MANAGER"));
        pool = IUniswapV3Pool(getAddr("POOL"));
        token0 = IERC20(getAddr("TOKEN0"));
        token1 = IERC20(getAddr("TOKEN1"));

        // Deploy diamond
        diamond = new SimplexDiamond();
        decomposer = new UniV3Decomposer(address(nftManager), address(diamond));
    }

    function deploySetup() internal virtual override {
        // For local testing without forking
        // This would deploy mock contracts
        // revert("Local setup not implemented - use forking");
    }

    /**
     * @notice Create a new Uniswap V3 position
     * @param tickLower Lower tick boundary
     * @param tickUpper Upper tick boundary
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param recipient Recipient of the position NFT
     * @return tokenId The NFT token ID
     * @return liquidity The liquidity amount
     * @return amount0 Actual amount of token0 used
     * @return amount1 Actual amount of token1 used
     */
    function createPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address recipient
    ) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Approve tokens
        token0.approve(address(nftManager), amount0Desired);
        token1.approve(address(nftManager), amount1Desired);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: pool.fee(),
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 3600
        });

        (tokenId, liquidity, amount0, amount1) = nftManager.mint(params);

        // Store position info
        positions[tokenId] = PositionInfo({
            owner: recipient,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: amount0,
            amount1: amount1
        });

        nextTokenId = tokenId + 1;
    }

    /**
     * @notice Increase liquidity of an existing position
     * @param tokenId The position NFT ID
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @return liquidity New liquidity amount
     * @return amount0 Actual amount of token0 used
     * @return amount1 Actual amount of token1 used
     */
    function increasePositionLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        // Approve tokens
        token0.approve(address(nftManager), amount0Desired);
        token1.approve(address(nftManager), amount1Desired);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 3600
            });

        (liquidity, amount0, amount1) = nftManager.increaseLiquidity(params);

        // Update stored position info
        PositionInfo storage pos = positions[tokenId];
        pos.liquidity += liquidity;
        pos.amount0 += amount0;
        pos.amount1 += amount1;
    }

    /**
     * @notice Decrease liquidity of an existing position
     * @param tokenId The position NFT ID
     * @param liquidityAmount Amount of liquidity to remove
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function decreasePositionLiquidity(
        uint256 tokenId,
        uint128 liquidityAmount
    ) internal returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityAmount,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 3600
            });

        (amount0, amount1) = nftManager.decreaseLiquidity(params);

        // Update stored position info
        PositionInfo storage pos = positions[tokenId];
        pos.liquidity -= liquidityAmount;
        pos.amount0 -= amount0;
        pos.amount1 -= amount1;
    }

    /**
     * @notice Collect fees from a position
     * @param tokenId The position NFT ID
     * @param recipient Recipient of collected fees
     * @return amount0 Amount of token0 collected
     * @return amount1 Amount of token1 collected
     */
    function collectPositionFees(
        uint256 tokenId,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: recipient,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (amount0, amount1) = nftManager.collect(params);
    }

    /**
     * @notice Burn a position NFT (removes all liquidity)
     * @param tokenId The position NFT ID
     */
    function burnPosition(uint256 tokenId) internal {
        // First decrease all liquidity
        PositionInfo storage pos = positions[tokenId];
        if (pos.liquidity > 0) {
            decreasePositionLiquidity(tokenId, pos.liquidity);
        }

        // Collect any remaining fees
        collectPositionFees(tokenId, address(this));

        // Burn the NFT
        nftManager.burn(tokenId);

        // Remove from tracking
        delete positions[tokenId];
    }

    /**
     * @notice Get tick spacing for a given fee tier
     * @param fee The fee tier
     * @return tickSpacing The tick spacing
     */
    function getTickSpacing(uint24 fee) internal pure returns (int24 tickSpacing) {
        if (fee == FEE_TIER_500) return TICK_SPACING_500;
        if (fee == FEE_TIER_3000) return TICK_SPACING_3000;
        if (fee == FEE_TIER_10000) return TICK_SPACING_10000;
        revert("Unsupported fee tier");
    }

    /**
     * @notice Get a valid tick within the tick spacing
     * @param tick The desired tick
     * @param fee The fee tier
     * @return validTick The nearest valid tick
     */
    function getValidTick(int24 tick, uint24 fee) internal pure returns (int24 validTick) {
        int24 spacing = getTickSpacing(fee);
        return (tick / spacing) * spacing;
    }

    /**
     * @notice Get pool information
     * @return fee The pool fee
     * @return tickSpacing The tick spacing
     * @return sqrtPriceX96 Current sqrt price
     * @return tick Current tick
     * @return liquidity Current liquidity
     */
    function getPoolInfo()
        internal
        view
        returns (uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96, int24 tick, uint128 liquidity)
    {
        fee = pool.fee();
        tickSpacing = getTickSpacing(fee);
        (sqrtPriceX96, tick, , , , , ) = pool.slot0();
        liquidity = pool.liquidity();
    }

    /**
     * @notice Get token balances for an address
     * @param user The user address
     * @return balance0 Token0 balance
     * @return balance1 Token1 balance
     */
    function getTokenBalances(address user) internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = token0.balanceOf(user);
        balance1 = token1.balanceOf(user);
    }

    /**
     * @notice Get position information
     * @param tokenId The position NFT ID
     * @return info The position information
     */
    function getPositionInfo(uint256 tokenId) internal view returns (PositionInfo memory info) {
        return positions[tokenId];
    }
}
