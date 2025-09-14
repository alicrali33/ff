// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "Commons/ERC/interfaces/IERC20.sol";
import { TickMath } from "v3-core/libraries/TickMath.sol";

import { AmmplifyForkBase } from "./AmmplifyForkBase.u.sol";

/**
 * @title AmmplifyIntegration
 * @notice Test contract for Ammplify integration with Uniswap V3
 * @dev Tests Ammplify's interaction with Uniswap positions
 */
contract Ammplify is AmmplifyForkBase {
    // Test user addresses
    address public user1;
    address public user2;

    // Position tracking
    uint256 public testPositionId;

    function forkSetup() internal virtual override {
        super.forkSetup();

        // Set up test users
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Fund users with tokens
        _fundUsers();
    }

    function _fundUsers() internal {
        // This would be implemented based on the fork setup
        // For now, we'll assume users have tokens or we'll mint them
        vm.startPrank(user1);
        // Add any necessary token minting or transfer logic here
        deal(address(token0), address(user1), type(uint256).max / 2);
        deal(address(token1), address(user1), type(uint256).max / 2);
        vm.stopPrank();

        vm.startPrank(user2);
        // Add any necessary token minting or transfer logic here
        deal(address(token0), address(user2), type(uint256).max / 2);
        deal(address(token1), address(user2), type(uint256).max / 2);
        vm.stopPrank();
    }

    function test_DiamondDeployment() public view forkOnly {
        // Verify diamond was deployed
        assertTrue(address(diamond) != address(0), "Diamond should be deployed");

        // Verify diamond has the expected facets
        // This would check that the diamond has the expected function selectors
        // For now, we'll just verify the address is not zero
    }

    function test_CreatePositionForAmmplify() public forkOnly {
        vm.startPrank(user1);

        // Get current pool info
        (uint24 fee, int24 tickSpacing, , int24 currentTick, ) = getPoolInfo();

        // Calculate valid tick range around current price
        int24 tickLower = getValidTick(currentTick - (tickSpacing * int24(10)), fee);
        int24 tickUpper = getValidTick(currentTick + (tickSpacing * int24(10)), fee);

        // Create position that could be used by Ammplify
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = createPosition(
            tickLower,
            tickUpper,
            1e18, // 1 token0
            1e18, // 1 token1
            user1
        );

        console2.log("tokenId", tokenId);
        console2.log("liquidity", liquidity);
        console2.log("amount0", amount0);
        console2.log("amount1", amount1);

        (
            uint96 nonce,
            address operator,
            ,
            ,
            ,
            ,
            ,
            uint128 liquidityPos,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = nftManager.positions(tokenId);

        // Console log all the position values
        console2.log("=== Position Details ===");
        console2.log("Token ID:", tokenId);
        console2.log("Nonce:", uint256(nonce));
        console2.log("Operator:", operator);
        console2.log("Fee:", fee);
        console2.log("Tick Lower:", tickLower);
        console2.log("Tick Upper:", tickUpper);
        console2.log("Liquidity:", liquidity);
        console2.log("LiquidityPos:", liquidityPos);
        console2.log("Fee Growth Inside0 Last X128:", feeGrowthInside0LastX128);
        console2.log("Fee Growth Inside1 Last X128:", feeGrowthInside1LastX128);
        console2.log("Tokens Owed0:", tokensOwed0);
        console2.log("Tokens Owed1:", tokensOwed1);
        console2.log("========================");

        nftManager.approve(address(decomposer), tokenId);

        // now decompose the position
        //         uint256 positionId,
        // bool isCompounding,
        // uint160 minSqrtPriceX96,
        // uint160 maxSqrtPriceX96,
        // bytes calldata rftData
        decomposer.decompose(
            tokenId,
            false,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            ""
        );

        // testPositionId = tokenId;

        // // Verify position was created successfully
        // assertTrue(tokenId > 0, "Position should have valid token ID");
        // assertTrue(liquidity > 0, "Position should have liquidity");

        // // Store position info for later use
        // PositionInfo memory pos = getPositionInfo(tokenId);
        // assertEq(pos.owner, user1, "Position owner should be user1");

        vm.stopPrank();
    }
}
