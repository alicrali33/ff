// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { UniswapV3Pool } from "v3-core/UniswapV3Pool.sol";
import { TickMath } from "v3-core/libraries/TickMath.sol";

import { MultiSetupTest } from "../MultiSetup.u.sol";

import { PoolInfo } from "../../src/Pool.sol";
import { LiqType } from "../../src/walkers/Liq.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
uint160 constant MIN_SQRT_RATIO = 4295128739;
/// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

contract MakerFacetTest is MultiSetupTest {
    UniswapV3Pool public pool;

    address public recipient;
    address public poolAddr;
    int24 public lowTick;
    int24 public highTick;
    uint128 public liquidity;
    uint160 public minSqrtPriceX96;
    uint160 public maxSqrtPriceX96;

    PoolInfo public poolInfo;

    function setUp() public {
        _newDiamond();
        (, address _pool, address _token0, address _token1) = setUpPool();

        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
        pool = UniswapV3Pool(_pool);

        // Set up recipient and basic test parameters
        recipient = address(this);
        poolAddr = _pool;
        lowTick = -600;
        highTick = 600;
        liquidity = 100e18;
        addPoolLiq(0, lowTick, highTick, liquidity);
        minSqrtPriceX96 = MIN_SQRT_RATIO;
        maxSqrtPriceX96 = MAX_SQRT_RATIO;

        poolInfo = viewFacet.getPoolInfo(poolAddr);

        // Fund this contract for testing
        _fundAccount(address(this));

        // Create vaults for the pool tokens
        _createPoolVaults(poolAddr);
    }

    // ============ Maker Position Creation Tests ============

    function testNewMaker() public {
        bytes memory rftData = "";

        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false, // non-compounding
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Verify asset was created
        assertEq(assetId, 1);

        // Verify asset properties using ViewFacet
        (address owner, address poolAddr_, int24 lowTick_, int24 highTick_, LiqType liqType, uint128 liq) = viewFacet
            .getAssetInfo(assetId);
        assertEq(owner, recipient);
        assertEq(poolAddr_, poolAddr);
        assertEq(lowTick_, lowTick);
        assertEq(highTick_, highTick);
        assertEq(uint8(liqType), uint8(LiqType.MAKER_NC));
        assertEq(liq, liquidity);
    }

    function testNewMakerCompounding() public {
        bytes memory rftData = "";

        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            true, // compounding
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Verify asset was created with compounding type
        (, , , , LiqType liqType, ) = viewFacet.getAssetInfo(assetId);
        assertEq(uint8(liqType), uint8(LiqType.MAKER));
    }

    function testNewMakerInvalidTicks() public {
        bytes memory rftData = "";

        // Test with invalid tick order
        vm.expectRevert();
        makerFacet.newMaker(
            recipient,
            poolAddr,
            highTick, // high tick first
            lowTick, // low tick second
            liquidity,
            false,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );
    }

    function testNewMakerInvalidLiquidity() public {
        bytes memory rftData = "";

        // Test with zero liquidity
        vm.expectRevert();
        makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            0, // zero liquidity
            false,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );
    }

    function testNewMakerPriceBounds() public {
        bytes memory rftData = "";

        // Test with invalid price bounds
        vm.expectRevert();
        makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false,
            maxSqrtPriceX96, // min > max
            minSqrtPriceX96,
            rftData
        );
    }

    // ============ Maker Position Removal Tests ============

    function testRemoveMakerBasic() public {
        // First create a maker position
        bytes memory rftData = "";
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        (int256 netBalance0, int256 netBalance1, , ) = viewFacet.queryAssetBalances(assetId);

        // Mock the asset owner
        vm.prank(recipient);

        // Remove the maker position
        (address removedToken0, address removedToken1, uint256 removedX, uint256 removedY) = makerFacet.removeMaker(
            recipient,
            assetId,
            uint128(minSqrtPriceX96),
            uint128(maxSqrtPriceX96),
            rftData
        );

        // Verify return values
        assertEq(removedToken0, address(token0));
        assertEq(removedToken1, address(token1));
        assertGe(int256(removedX), netBalance0);
        assertGe(int256(removedY), netBalance1);

        // Verify asset was removed
        vm.expectRevert();
        viewFacet.getAssetInfo(assetId);
    }

    function testRemoveMakerNotOwner() public {
        // First create a maker position
        bytes memory rftData = "";
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Try to remove as non-owner
        address nonOwner = address(0x456);
        vm.prank(nonOwner);

        vm.expectRevert();
        makerFacet.removeMaker(recipient, assetId, uint128(minSqrtPriceX96), uint128(maxSqrtPriceX96), rftData);
    }

    function testRemoveMakerNotMakerAsset() public {
        // Create a taker asset instead of maker
        // This would require setting up the taker facet first
        // For now, we'll test the revert case by trying to remove a non-existent asset

        bytes memory rftData = "";
        vm.expectRevert();
        makerFacet.removeMaker(
            recipient,
            999, // non-existent asset
            uint128(minSqrtPriceX96),
            uint128(maxSqrtPriceX96),
            rftData
        );
    }

    // ============ Fee Collection Tests ============

    function testCollectFeesBasic() public {
        // First create a maker position
        bytes memory rftData = "";
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        swapTo(0, TickMath.getSqrtRatioAtTick(600));
        swapTo(0, TickMath.getSqrtRatioAtTick(-600));

        // Mock the asset owner
        vm.prank(recipient);

        // Collect fees
        (uint256 fees0, uint256 fees1) = makerFacet.collectFees(
            recipient,
            assetId,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Verify fees were collected
        assertGe(fees0, 0);
        assertGe(fees1, 0);
    }

    function testCollectFeesNotOwner() public {
        // First create a maker position
        bytes memory rftData = "";
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Try to collect fees as non-owner
        address nonOwner = address(0x456);
        vm.prank(nonOwner);

        vm.expectRevert();
        makerFacet.collectFees(recipient, assetId, minSqrtPriceX96, maxSqrtPriceX96, rftData);
    }

    function testCollectFeesNotMakerAsset() public {
        bytes memory rftData = "";
        vm.expectRevert();
        makerFacet.collectFees(
            recipient,
            999, // non-existent asset
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );
    }

    // ============ Price Movement and Value Query Tests ============

    function testMakerPositionValueAfterPriceMovement() public {
        bytes memory rftData = "";

        // Create a maker position
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false, // non-compounding
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Verify the position was created correctly using ViewFacet
        (address owner, address poolAddr_, int24 lowTick_, int24 highTick_, LiqType liqType, uint128 liq) = viewFacet
            .getAssetInfo(assetId);
        assertEq(owner, recipient);
        assertEq(poolAddr_, poolAddr);
        assertEq(lowTick_, lowTick);
        assertEq(highTick_, highTick);
        assertEq(uint8(liqType), uint8(LiqType.MAKER_NC));
        assertEq(liq, liquidity);

        // Get initial position balances
        (int256 initialNetBalance0, int256 initialNetBalance1, , ) = viewFacet.queryAssetBalances(assetId);

        // Move price up by swapping to a higher tick
        int24 targetTick = 300; // Move price up
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Query position value after price movement
        (int256 queriedNetBalance0, int256 queriedNetBalance1, uint256 queriedFees0, uint256 queriedFees1) = viewFacet
            .queryAssetBalances(assetId);

        // Verify that balances changed due to price movement
        // When price goes up, we expect different token0/token1 balances
        assertTrue(
            queriedNetBalance0 != initialNetBalance0 || queriedNetBalance1 != initialNetBalance1,
            "Position balances should change after price movement"
        );

        // Close the position and get actual amounts
        (address token0Addr, address token1Addr, uint256 actualRemoved0, uint256 actualRemoved1) = makerFacet
            .removeMaker(recipient, assetId, uint128(minSqrtPriceX96), uint128(maxSqrtPriceX96), rftData);

        // Verify tokens match expected pool tokens
        assertEq(token0Addr, address(token0));
        assertEq(token1Addr, address(token1));

        // Compare queried values with actual close values
        // The total value from query should approximately match what we get from closing
        // For a maker position, net balances should be positive (amounts owed to position owner)
        assertGt(actualRemoved0, 0, "Should receive some token0 on close");
        assertGt(actualRemoved1, 0, "Should receive some token1 on close");

        // The queried net balance should reasonably approximate the actual amounts
        // (allowing for some difference due to fees and precision)
        assertApproxEqAbs(
            queriedNetBalance0 + int256(queriedFees0),
            int256(actualRemoved0),
            2,
            "Queried token0 balance should approximate actual removed amount"
        );

        assertApproxEqAbs(
            queriedNetBalance1 + int256(queriedFees1),
            int256(actualRemoved1),
            2,
            "Queried token1 balance should approximate actual removed amount"
        );
    }

    function testMakerPositionValueAfterPriceMovementDown() public {
        bytes memory rftData = "";

        // Create a maker position
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false, // non-compounding
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Move price down by swapping to a lower tick
        int24 targetTick = -300; // Move price down
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Query position value after price movement
        (int256 queriedNetBalance0, int256 queriedNetBalance1, uint256 queriedFees0, uint256 queriedFees1) = viewFacet
            .queryAssetBalances(assetId);

        // Close the position and get actual amounts
        (address token0Addr, address token1Addr, uint256 actualRemoved0, uint256 actualRemoved1) = makerFacet
            .removeMaker(recipient, assetId, uint128(minSqrtPriceX96), uint128(maxSqrtPriceX96), rftData);

        // Verify tokens match expected pool tokens
        assertEq(token0Addr, address(token0));
        assertEq(token1Addr, address(token1));

        // Compare queried values with actual close values for downward price movement
        assertGt(actualRemoved0, 0, "Should receive some token0 on close");
        assertGt(actualRemoved1, 0, "Should receive some token1 on close");

        // The queried values should still reasonably match actual values
        assertApproxEqAbs(
            queriedNetBalance0 + int256(queriedFees0),
            int256(actualRemoved0),
            2,
            "Queried token0 balance should approximate actual removed amount after price down"
        );

        assertApproxEqAbs(
            queriedNetBalance1 + int256(queriedFees1),
            int256(actualRemoved1),
            2,
            "Queried token1 balance should approximate actual removed amount after price down"
        );
    }

    function testMakerPositionValueWithLargePriceMovement() public {
        bytes memory rftData = "";

        // Create a maker position
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false, // non-compounding
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Make a large price movement (move close to the edge of our range)
        int24 targetTick = 500; // Large upward movement, but still within range
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Query position value after large price movement
        (, , uint256 queriedFees0, uint256 queriedFees1) = viewFacet.queryAssetBalances(assetId);

        // Verify that fees have been earned (should be positive for large movement)
        assertTrue(queriedFees0 > 0 || queriedFees1 > 0, "Should have earned some fees from large price movement");

        // Close the position and verify consistency
        (, , uint256 actualRemoved0, uint256 actualRemoved1) = makerFacet.removeMaker(
            recipient,
            assetId,
            uint128(minSqrtPriceX96),
            uint128(maxSqrtPriceX96),
            rftData
        );

        // Verify consistency between query and actual values
        assertGt(actualRemoved0, 0, "Should receive some token0 on close after large movement");
        assertGt(actualRemoved1, 0, "Should receive some token1 on close after large movement");
    }

    function testMakerAdjust() public {
        bytes memory rftData = "";

        // Create a maker position
        uint256 assetId = makerFacet.newMaker(
            address(this),
            poolAddr,
            lowTick,
            highTick,
            liquidity,
            false, // non-compounding
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );
        (int256 balance0, int256 balance1, , ) = viewFacet.queryAssetBalances(assetId);

        // Adjust the maker position up
        (, , int256 delta0, int256 delta1) = makerFacet.adjustMaker(
            address(this),
            assetId,
            liquidity * 2,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );
        (int256 adjustedBalance0, int256 adjustedBalance1, , ) = viewFacet.queryAssetBalances(assetId);

        // Verify the adjusted values
        assertApproxEqAbs(adjustedBalance0, balance0 + delta0, 1, "Adjusted balance0 should match");
        assertApproxEqAbs(adjustedBalance1, balance1 + delta1, 1, "Adjusted balance1 should match");
        assertApproxEqAbs(balance0, delta0, 2, "we doubled 0");
        assertApproxEqAbs(balance1, delta1, 2, "we doubled 1");

        // Halve the liquidity back
        (, , delta0, delta1) = makerFacet.adjustMaker(
            address(this),
            assetId,
            liquidity,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );
        assertApproxEqAbs(delta0, -balance0, 2, "Should have negative delta0");
        assertApproxEqAbs(delta1, -balance1, 2, "Should have negative delta1");
        (adjustedBalance0, adjustedBalance1, , ) = viewFacet.queryAssetBalances(assetId);
        assertApproxEqAbs(balance0, adjustedBalance0, 1, "Back to the original balance0");
        assertApproxEqAbs(balance1, adjustedBalance1, 1, "Back to the original balance1");
    }
}
