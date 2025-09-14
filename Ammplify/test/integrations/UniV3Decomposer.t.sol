// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { NonfungiblePositionManager } from "../mocks/nfpm/NonfungiblePositionManager.sol";
import { UniV3Decomposer } from "../../src/integrations/UniV3Decomposer.sol";
import { MultiSetupTest } from "../MultiSetup.u.sol";
import { MockERC20 } from "./../mocks/MockERC20.sol";
import { INonfungiblePositionManager } from "../mocks/nfpm/interfaces/INonfungiblePositionManager.sol";

contract UniV3DecomposerTest is MultiSetupTest {
    UniV3Decomposer private decomposer;

    function setUp() public {
        _newDiamond();
        _deployNFPM();

        (, , address _token0, address _token1) = setUpPool();
        token0 = MockERC20(_token0);
        token1 = MockERC20(_token1);
        decomposer = new UniV3Decomposer(address(nfpm), address(diamond));
        addPoolLiq(0, -600, 600, 1e18);
    }

    // Helper function to create a position using the mint function
    function createPosition(
        address owner,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint256) {
        // Fund the owner with tokens
        token0.mint(owner, amount0Desired);
        token1.mint(owner, amount1Desired);

        // Approve the NFPM to spend tokens
        vm.startPrank(owner);
        token0.approve(address(nfpm), amount0Desired);
        token1.approve(address(nfpm), amount1Desired);
        vm.stopPrank();

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: owner,
            deadline: block.timestamp + 3600
        });

        (uint256 tokenId, , , ) = nfpm.mint(params);
        return tokenId;
    }

    function testRevertNotOwner() public {
        uint256 pos = createPosition(address(0xBEEF), 3000, -600, 600, 1e18, 1e18);
        vm.prank(address(0xBEEF));
        nfpm.approve(address(decomposer), pos);
        vm.expectRevert();
        decomposer.decompose(pos, false, 0, 0, "");
    }

    function testDecomposeNFT() public {
        uint256 pos = createPosition(address(this), 3000, -600, 600, 1e18, 1e18);
        nfpm.setApprovalForAll(address(decomposer), true);

        // Set reasonable price bounds - allowing full range to avoid slippage issues
        uint160 minSqrtPriceX96 = 4295128739; // Very low price
        uint160 maxSqrtPriceX96 = 1461446703485210103287273052203988822378723970341; // Very high price
        decomposer.decompose(pos, false, minSqrtPriceX96, maxSqrtPriceX96, "");
    }
}
