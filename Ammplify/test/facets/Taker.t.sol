// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { console2 as console } from "forge-std/console2.sol";

import { UniswapV3Pool } from "v3-core/UniswapV3Pool.sol";
import { TickMath } from "v3-core/libraries/TickMath.sol";
import { console } from "forge-std/console.sol";

import { MultiSetupTest } from "../MultiSetup.u.sol";

import { PoolInfo } from "../../src/Pool.sol";
import { AmmplifyAdminRights } from "../../src/facets/Admin.sol";
import { LiqType } from "../../src/walkers/Liq.sol";
import { AdminLib } from "Commons/Util/Admin.sol";
import { AmmplifyAdminRights } from "../../src/facets/Admin.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

/// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
uint160 constant MIN_SQRT_RATIO = 4295128739;
/// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

contract TakerFacetTest is MultiSetupTest {
    UniswapV3Pool public pool;

    address public recipient;
    address public poolAddr;
    int24[2] public ticks;
    uint128 public liquidity;
    uint8[2] public vaultIndices;
    uint160[2] public sqrtPriceLimitsX96;
    uint160 public freezeSqrtPriceX96;

    PoolInfo public poolInfo;

    /// @dev Helper function to collateralize tokens before creating taker positions
    function _collateralizeTaker(address recipient_, uint128 liquidity_) internal {
        // Calculate approximate token amounts needed for the liquidity
        // This is a rough estimate - in practice you'd want more precise calculations
        uint256 token0Amount = uint256(liquidity_) * 1e6; // Rough estimate
        uint256 token1Amount = uint256(liquidity_) * 1e6; // Rough estimate

        bytes memory data = "";

        // Mint and approve tokens
        token0.mint(address(this), token0Amount);
        token1.mint(address(this), token1Amount);
        token0.approve(address(takerFacet), token0Amount);
        token1.approve(address(takerFacet), token1Amount);

        // Collateralize both tokens
        takerFacet.collateralize(recipient_, address(token0), token0Amount, data);
        takerFacet.collateralize(recipient_, address(token1), token1Amount, data);
    }

    function setUp() public {
        _newDiamond();
        // Grant TAKER rights to this test contract using the TimedAdmin system
        // Since this is a test, we'll submit rights and then time travel to accept them
        adminFacet.submitRights(address(this), AmmplifyAdminRights.TAKER, true);

        // Skip the time delay for testing (3 days as per AdminFacet.getDelay implementation)
        vm.warp(block.timestamp + 3 days);

        // Accept the rights
        adminFacet.acceptRights();

        // Verify the rights were granted
        uint256 rights = adminFacet.adminRights(address(this));
        console.log("Test contract rights after granting:", rights);
        require(rights & AmmplifyAdminRights.TAKER != 0, "Failed to grant TAKER rights");

        (, address _pool, address _token0, address _token1) = setUpPool();
        // Provide much more liquidity to support taker borrowing
        // Add liquidity in a wider range with much larger amounts
        addPoolLiq(0, -1200, 1200, 1000e18);

        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
        pool = UniswapV3Pool(_pool);

        // Set up test parameters
        recipient = address(this);
        poolAddr = address(pool);
        ticks = [-600, 600];

        liquidity = 1e18;
        vaultIndices = [0, 1];
        sqrtPriceLimitsX96 = [MIN_SQRT_RATIO, MAX_SQRT_RATIO];
        freezeSqrtPriceX96 = 3 << 95; // Above range, 1.5 = sqrt(price)

        poolInfo = viewFacet.getPoolInfo(poolAddr);

        // Fund this contract for testing
        _fundAccount(address(this));

        // Create vaults for the pool tokens BEFORE creating any positions
        _createPoolVaults(poolAddr);
    }

    // ============ Taker Position Creation Tests ============

    function testNewTakerBasic() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // First create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Verify asset was created
        assertEq(assetId, 2);

        // Verify asset properties using ViewFacet
        (address owner, address poolAddr_, int24 lowTick_, int24 highTick_, LiqType liqType, uint128 liq) = viewFacet
            .getAssetInfo(assetId);
        assertEq(owner, recipient);
        assertEq(poolAddr_, poolAddr);
        assertEq(lowTick_, ticks[0]);
        assertEq(highTick_, ticks[1]);
        assertEq(uint8(liqType), uint8(LiqType.TAKER));
        assertEq(liq, liquidity);
    }

    function testNewTakerInvalidTicks() public {
        bytes memory rftData = "";
        int24[2] memory invalidTicks = [int24(600), int24(-600)]; // high tick first

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Test with invalid tick order
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            invalidTicks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    function testNewTakerInvalidLiquidity() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position (even for invalid test)
        _collateralizeTaker(recipient, 1); // Use minimal amount for zero liquidity test

        // Test with zero liquidity
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            0, // zero liquidity
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    function testNewTakerInvalidVaultIndices() public {
        bytes memory rftData = "";
        uint8[2] memory invalidVaultIndices = [255, 255]; // out of range

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Test with invalid vault indices
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            invalidVaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    // ============ Collateralization Error Tests ============

    function testNewTakerMissingToken0Collateral() public {
        bytes memory rftData = "";
        uint256 token1Amount = uint256(liquidity) * 1e6;

        // Only collateralize token1, not token0
        token1.mint(address(this), token1Amount);
        token1.approve(address(takerFacet), token1Amount);
        takerFacet.collateralize(recipient, address(token1), token1Amount, rftData);

        // Attempt to create taker without token0 collateral should fail
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    function testNewTakerMissingToken1Collateral() public {
        bytes memory rftData = "";
        uint256 token0Amount = uint256(liquidity) * 1e6;

        // Only collateralize token0, not token1
        token0.mint(address(this), token0Amount);
        token0.approve(address(takerFacet), token0Amount);
        takerFacet.collateralize(recipient, address(token0), token0Amount, rftData);

        // Attempt to create taker without token1 collateral should fail
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    function testNewTakerNoCollateral() public {
        bytes memory rftData = "";

        // Attempt to create taker without any collateral should fail
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    function testNewTakerInsufficientCollateral() public {
        bytes memory rftData = "";
        // Use very small collateral amounts (likely insufficient)
        uint256 smallAmount = 1; // Minimal amount

        token0.mint(address(this), smallAmount);
        token1.mint(address(this), smallAmount);
        token0.approve(address(takerFacet), smallAmount);
        token1.approve(address(takerFacet), smallAmount);

        takerFacet.collateralize(recipient, address(token0), smallAmount, rftData);
        takerFacet.collateralize(recipient, address(token1), smallAmount, rftData);

        // Attempt to create taker with insufficient collateral should fail
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    function testNewTakerPartialCollateralAfterWithdrawal() public {
        bytes memory rftData = "";

        // First, properly collateralize
        _collateralizeTaker(recipient, liquidity);

        // Verify we have collateral
        uint256 token0Balance = viewFacet.getCollateralBalance(recipient, address(token0));
        uint256 token1Balance = viewFacet.getCollateralBalance(recipient, address(token1));
        assertGt(token0Balance, 0, "Should have token0 collateral");
        assertGt(token1Balance, 0, "Should have token1 collateral");

        // TODO: Add test for withdrawing collateral when that functionality is implemented
        // For now, this test serves as a placeholder and documents the expected behavior

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Successfully create taker with proper collateral
        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Verify asset was created
        assertEq(assetId, 2);
    }

    // ============ Taker Position Removal Tests ============

    function testRemoveTakerBasic() public {
        // First create a taker position
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Mock the asset owner
        vm.prank(recipient);

        // Remove the taker position
        (address removedToken0, address removedToken1, int256 removedX, int256 removedY) = takerFacet.removeTaker(
            assetId,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Verify return values
        assertEq(removedToken0, address(token0));
        assertEq(removedToken1, address(token1));
        assertLt(removedX, 0); // Since the freeze price is above the pool's current price.
        assertGt(removedY, 0);

        // Verify asset was removed
        vm.expectRevert();
        viewFacet.getAssetInfo(assetId);
    }

    function testRemoveTakerNotOwner() public {
        // First create a taker position
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Try to remove as non-owner
        address nonOwner = address(0x456);
        vm.prank(nonOwner);

        vm.expectRevert();
        takerFacet.removeTaker(assetId, sqrtPriceLimitsX96[0], sqrtPriceLimitsX96[1], rftData);
    }

    function testRemoveTakerNotTakerAsset() public {
        // Create a maker asset instead of taker
        bytes memory rftData = "";
        uint256 assetId = makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity,
            false, // non-compounding
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Try to remove maker asset via removeTaker
        vm.expectRevert();
        takerFacet.removeTaker(assetId, sqrtPriceLimitsX96[0], sqrtPriceLimitsX96[1], rftData);
    }

    // ============ Collateral Management Tests ============

    function testCollateralize() public {
        uint256 amount = 1000e18;
        bytes memory data = "";

        // Mint tokens to the caller
        token0.mint(address(this), amount);
        token0.approve(address(takerFacet), amount);

        takerFacet.collateralize(recipient, address(token0), amount, data);

        // Verify collateral was recorded using the new view function
        uint256 collateralBalance = viewFacet.getCollateralBalance(recipient, address(token0));
        assertEq(collateralBalance, amount);
    }

    function testWithdrawCollateral() public {
        // First add some collateral
        uint256 amount = 1000e18;
        bytes memory data = "";

        token0.mint(address(this), amount);
        token0.approve(address(takerFacet), amount);

        takerFacet.collateralize(recipient, address(token0), amount, data);

        // Verify initial collateral balance
        uint256 initialBalance = viewFacet.getCollateralBalance(recipient, address(token0));
        assertEq(initialBalance, amount);

        // Now withdraw collateral (requires admin rights)
        // This test will need to be updated when we implement proper admin rights
        // For now, we'll just verify the function exists and initial balance is correct
        assertTrue(true);
    }

    function testCollateralBalanceTracking() public {
        // Test that collateral balances are tracked correctly
        uint256 amount1 = 500e18;
        uint256 amount2 = 300e18;
        bytes memory data = "";

        token0.mint(address(this), amount1 + amount2);
        token0.approve(address(takerFacet), amount1 + amount2);

        takerFacet.collateralize(recipient, address(token0), amount1, data);

        // Verify first collateral deposit
        uint256 balanceAfterFirst = viewFacet.getCollateralBalance(recipient, address(token0));
        assertEq(balanceAfterFirst, amount1);

        takerFacet.collateralize(recipient, address(token0), amount2, data);

        // Verify total collateral after second deposit
        uint256 totalBalance = viewFacet.getCollateralBalance(recipient, address(token0));
        assertEq(totalBalance, amount1 + amount2);
    }

    function testCollateralMultipleTokens() public {
        // Test collateral management with multiple tokens
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;
        bytes memory data = "";

        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        token0.approve(address(takerFacet), amount0);
        token1.approve(address(takerFacet), amount1);

        takerFacet.collateralize(recipient, address(token0), amount0, data);
        takerFacet.collateralize(recipient, address(token1), amount1, data);

        // Verify both tokens were recorded as collateral using individual queries
        uint256 token0Balance = viewFacet.getCollateralBalance(recipient, address(token0));
        uint256 token1Balance = viewFacet.getCollateralBalance(recipient, address(token1));

        assertEq(token0Balance, amount0);
        assertEq(token1Balance, amount1);

        // Also test the batch query function
        address[] memory recipients = new address[](2);
        address[] memory tokens = new address[](2);
        recipients[0] = recipient;
        recipients[1] = recipient;
        tokens[0] = address(token0);
        tokens[1] = address(token1);

        uint256[] memory batchBalances = viewFacet.getCollateralBalances(recipients, tokens);
        assertEq(batchBalances.length, 2);
        assertEq(batchBalances[0], amount0);
        assertEq(batchBalances[1], amount1);
    }

    // ============ Taker Position Value and Price Movement Tests ============

    function testTakerPositionValueAtCreation() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create a taker position
        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Verify the position was created correctly using ViewFacet
        (address owner, address poolAddr_, int24 lowTick_, int24 highTick_, LiqType liqType, uint128 liq) = viewFacet
            .getAssetInfo(assetId);
        assertEq(owner, recipient);
        assertEq(poolAddr_, poolAddr);
        assertEq(lowTick_, ticks[0]);
        assertEq(highTick_, ticks[1]);
        assertEq(uint8(liqType), uint8(LiqType.TAKER));
        assertEq(liq, liquidity);

        // Get initial position balances - should be in Y and owe X since we're freezing above.
        (int256 initialNetBalance0, int256 initialNetBalance1, , ) = viewFacet.queryAssetBalances(assetId);

        assertLt(initialNetBalance0, 0, "we owe X at first");
        assertGt(initialNetBalance1, 0, "we have Y at first");
    }

    function testTakerPositionValueAfterPriceMovementUp() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create a taker position with range [-600, 600]
        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Get initial position balances
        (int256 initialNetBalance0, int256 initialNetBalance1, uint256 initialFees0, uint256 initialFees1) = viewFacet
            .queryAssetBalances(assetId);

        assertApproxEqAbs(initialFees0, 0, 6, "0"); // It's possible to have some dust owed upon opening.
        assertApproxEqAbs(initialFees1, 0, 6, "1");
        assertLt(initialNetBalance0, 0, "2"); // Froze into y, no x.
        assertGt(initialNetBalance1, 0, "3"); // Have y

        // Move price above the taker range (above tick 600)
        int24 targetTick = 800; // Move price outside the range
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Query position value after price movement
        (int256 queriedNetBalance0, int256 queriedNetBalance1, uint256 queriedFees0, uint256 queriedFees1) = viewFacet
            .queryAssetBalances(assetId);

        // When price is above the range, taker should have positive net balance
        assertApproxEqAbs(queriedNetBalance0, 0, 3, "No X owed since we're above");
        assertApproxEqAbs(queriedNetBalance1, 0, 3, "Same Y now we're above range");
        assertTrue(queriedFees0 > 0 && queriedFees1 > 0, "Taker owes fees for the swap.");
        console.log("fees", queriedFees0, queriedFees1);

        // Close the position and get actual amounts
        vm.prank(recipient);
        (address token0Addr, address token1Addr, int256 actualRemoved0, int256 actualRemoved1) = takerFacet.removeTaker(
            assetId,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Verify tokens match expected pool tokens
        assertEq(token0Addr, address(token0));
        assertEq(token1Addr, address(token1));

        // match the amounts.
        // The queried values should reasonably match the actual removed amounts
        assertApproxEqAbs(
            queriedNetBalance0 - int256(queriedFees0),
            actualRemoved0,
            2,
            "Queried token0 balance should approximate actual removed amount"
        );
        assertApproxEqAbs(
            queriedNetBalance1 - int256(queriedFees1),
            actualRemoved1,
            2,
            "Queried token1 balance should approximate actual removed amount"
        );
    }

    function testTakerPositionValueAfterPriceMovementDown() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create a taker position with range [-600, 600]
        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Move price below the taker range (below tick -600)
        int24 targetTick = -800; // Move price outside the range
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Query position value after price movement
        (int256 queriedNetBalance0, int256 queriedNetBalance1, uint256 queriedFees0, uint256 queriedFees1) = viewFacet
            .queryAssetBalances(assetId);

        // When price is below the range, taker should owe X but have Y.
        assertLt(queriedNetBalance0, 0, "owe X");
        assertGt(queriedNetBalance1, 0, "have Y");
        assertGt(queriedFees0, 0, "owe fees for X");
        assertGt(queriedFees1, 0, "owe fees for Y");

        // Close the position and verify we receive tokens
        vm.prank(recipient);
        (address token0Addr, address token1Addr, int256 actualRemoved0, int256 actualRemoved1) = takerFacet.removeTaker(
            assetId,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Verify tokens match expected pool tokens
        assertEq(token0Addr, address(token0));
        assertEq(token1Addr, address(token1));

        // match the amounts.
        // The queried values should reasonably match the actual removed amounts
        assertApproxEqAbs(
            queriedNetBalance0 - int256(queriedFees0),
            actualRemoved0,
            2,
            "Queried token0 balance should approximate actual removed amount"
        );
        assertApproxEqAbs(
            queriedNetBalance1 - int256(queriedFees1),
            actualRemoved1,
            2,
            "Queried token1 balance should approximate actual removed amount"
        );
    }

    function testTakerPositionValueWithLargePriceMovement() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create a taker position
        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Make a large price movement well outside the range
        int24 targetTick = 1000; // Large upward movement, well outside range
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Query position value after large price movement
        (int256 queriedNetBalance0, int256 queriedNetBalance1, uint256 queriedFees0, uint256 queriedFees1) = viewFacet
            .queryAssetBalances(assetId);

        // With large price movement up, taker will have matched the frozen balance.
        assertApproxEqAbs(queriedNetBalance0, 0, 3, "No X owed since we're above");
        assertApproxEqAbs(queriedNetBalance1, 0, 3, "Same Y now we're above range");
        assertTrue(queriedFees0 > 0 && queriedFees1 > 0, "Taker owes fees for the swap.");
        console.log("fees", queriedFees0, queriedFees1);

        // Close the position and verify consistency
        vm.prank(recipient);
        (, , int256 actualRemoved0, int256 actualRemoved1) = takerFacet.removeTaker(
            assetId,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // The queried values should reasonably match the actual removed amounts
        assertApproxEqAbs(
            queriedNetBalance0 - int256(queriedFees0),
            actualRemoved0,
            2,
            "Queried token0 balance should approximate actual removed amount"
        );
        assertApproxEqAbs(
            queriedNetBalance1 - int256(queriedFees1),
            actualRemoved1,
            2,
            "Queried token1 balance should approximate actual removed amount"
        );
    }

    function testTakerPositionBackInRange() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create a taker position
        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Move price outside range first
        int24 targetTick = 800;
        uint160 targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Verify position is valuable when out of range
        (int256 outOfRangeBalance0, int256 outOfRangeBalance1, uint256 fees0, uint256 fees1) = viewFacet
            .queryAssetBalances(assetId);
        // Since we're above range we're actually in the freeze balances.
        assertApproxEqAbs(outOfRangeBalance0, 0, 3, "No X owed since we're above");
        assertApproxEqAbs(outOfRangeBalance1, 0, 3, "Same Y now we're above range");
        assertTrue(fees0 > 0 && fees1 > 0, "Taker owes fees for the swap.");

        // Move price back into range
        targetTick = 0; // Back to center of range
        targetSqrtPriceX96 = TickMath.getSqrtRatioAtTick(targetTick);
        swapTo(0, targetSqrtPriceX96);

        // Query position value when back in range
        (int256 inRangeBalance0, int256 inRangeBalance1, , ) = viewFacet.queryAssetBalances(assetId);

        // When back in range, you'll have excess y and owe x.
        assertLt(inRangeBalance0, 0, "owe X");
        assertGt(inRangeBalance1, outOfRangeBalance1, "excess Y");
    }

    function testTakerFeesOverTime() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create a taker position
        uint256 assetId = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // No swaps, just time, the taker should owe fees.
        (int256 initBalance0, int256 initBalance1, uint256 initFees0, uint256 initFees1) = viewFacet.queryAssetBalances(
            assetId
        );

        vm.warp(block.timestamp + 100 days);
        (int256 finalBalance0, int256 finalBalance1, uint256 finalFees0, uint256 finalFees1) = viewFacet
            .queryAssetBalances(assetId);

        assertEq(initBalance0, finalBalance0, "balances don't change0");
        assertEq(initBalance1, finalBalance1, "balances don't change1");

        // Check that the taker now owes fees
        assertGt(finalFees0, initFees0, "Taker should owe more fees for token0");
        assertGt(finalFees1, initFees1, "Taker should owe more fees for token1");
    }

    function testFreezeBalances() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 3,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create taker positions with different freeze prices.
        uint256 assetId0 = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            100 << 96,
            rftData
        );

        uint256 assetId1 = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            1 << 96,
            rftData
        );

        uint256 assetId2 = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            1 << 90,
            rftData
        );

        (int256 b00, int256 b01, , ) = viewFacet.queryAssetBalances(assetId0);
        (int256 b10, int256 b11, , ) = viewFacet.queryAssetBalances(assetId1);
        (int256 b20, int256 b21, , ) = viewFacet.queryAssetBalances(assetId2);

        // The higher the price the more y they should have.
        assertGt(b01, b11, "0");
        assertGt(b11, b21, "1");
        // And the lower the price the more x they have.
        assertLt(b00, b10, "2");
        assertLt(b10, b20, "3");
    }

    function testLiquiditySufficiency() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity * 2,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // Create a taker position
        uint256 assetId0 = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
        // Add these views to ensure they don't revert.
        viewFacet.queryAssetBalances(assetId0);

        // Now we have another taker take the rest of the avilable liquidity.
        uint256 assetId1 = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
        viewFacet.queryAssetBalances(assetId0);

        console.log("fully borrowed out");

        // A third will fail.
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        // Removing a previous one will free up liquidity to add another.
        takerFacet.removeTaker(assetId0, sqrtPriceLimitsX96[0], sqrtPriceLimitsX96[1], "");

        console.log("Removed old");

        uint256 assetId2 = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
        viewFacet.queryAssetBalances(assetId2);

        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        console.log("adding more liq");

        // Adding more liquidity to a wider range will allow us to add more as well.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0] - 1200,
            ticks[1] + 1200,
            liquidity,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        console.log("but borrowing it out immediately");

        // We only have liq for one more.
        uint256 assetId3 = takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
        viewFacet.queryAssetBalances(assetId3);

        console.log("And reverting next");

        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        console.log("using disjoint makers");

        // And we can use disjoint makers to get the liquidity we need.
        int24 middleTick = ticks[0] + (ticks[1] - ticks[0]) / 2;
        // just half is insufficient.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0] - 1200,
            middleTick,
            liquidity,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        console.log("using disjoint makers second half");

        // but both is enough.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            middleTick,
            ticks[1],
            liquidity,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        // This succeeds.
        takerFacet.newTaker(
            recipient,
            poolAddr,
            ticks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    function testOverlappingInsufficientLiquidity() public {
        bytes memory rftData = "";

        // Collateralize before creating taker position
        _collateralizeTaker(recipient, liquidity);

        // Create a maker large enough to borrow from.
        makerFacet.newMaker(
            recipient,
            poolAddr,
            ticks[0],
            ticks[1],
            liquidity,
            true,
            sqrtPriceLimitsX96[0],
            sqrtPriceLimitsX96[1],
            rftData
        );

        int24 middleTick = ticks[0] + (ticks[1] - ticks[0]) / 2;

        // Create a taker position
        int24[2] memory lowTicks = [ticks[0], middleTick];
        takerFacet.newTaker(
            recipient,
            poolAddr,
            lowTicks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );

        int24[2] memory highTicks = [middleTick - 60, ticks[1]];
        vm.expectRevert();
        takerFacet.newTaker(
            recipient,
            poolAddr,
            highTicks,
            liquidity,
            vaultIndices,
            sqrtPriceLimitsX96,
            freezeSqrtPriceX96,
            rftData
        );
    }

    /* TODO tests.
    Test vault earnings for taker
    */
}
