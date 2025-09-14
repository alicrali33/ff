// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { UniswapV3Factory } from "v3-core/UniswapV3Factory.sol";
import { UniswapV3Pool } from "v3-core/UniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";
import { Strings } from "a@openzeppelin/contracts/utils/Strings.sol";
import { IERC20 } from "a@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TransferHelper } from "Commons/Util/TransferHelper.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";
import { TickMath } from "v3-core/libraries/TickMath.sol";

contract UniV3IntegrationSetup is IUniswapV3MintCallback, IUniswapV3SwapCallback {
    uint160 public constant INIT_SQRT_PRICEX96 = 1 << 96;
    UniswapV3Factory public factory;
    // NOTE: You don't need to store the return values of any of the setup functions besides idx
    // because you can retrieve the relevant information from here.
    address[] public pools;
    address[] public poolToken0s;
    address[] public poolToken1s;
    uint256 public _idx;

    constructor() {
        factory = new UniswapV3Factory();
    }

    function setUpPool() public returns (uint256 idx, address pool, address token0, address token1) {
        return setUpPool(3000);
    }

    function setUpPool(uint24 fee) public returns (uint256 idx, address pool, address token0, address token1) {
        // Give a little of a buffer, but still more than enough.
        return setUpPool(fee, type(uint256).max / 2, 0, INIT_SQRT_PRICEX96);
    }

    function setUpPool(
        uint24 fee,
        uint256 initialMint,
        uint128 initialLiq,
        uint160 initialPriceX96
    ) public returns (uint256 idx, address pool, address token0, address token1) {
        uint256 __idx = pools.length;
        string memory numString = Strings.toString(__idx);
        address tokenA = address(
            new MockERC20(string.concat("UniPoolToken A.", numString), string.concat("UPT.A.", numString), 18)
        );
        address tokenB = address(
            new MockERC20(string.concat("UniPoolToken B.", numString), string.concat("UPT.B.", numString), 18)
        );
        MockERC20(tokenA).mint(address(this), initialMint);
        MockERC20(tokenB).mint(address(this), initialMint);
        if (tokenA < tokenB) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        (idx, pool) = setUpPool(token0, token1, fee, initialLiq, initialPriceX96);
    }

    function setUpPool(address token0, address token1) public returns (uint256 idx, address pool) {
        return setUpPool(token0, token1, 3000, 0, INIT_SQRT_PRICEX96);
    }

    function setUpPool(
        address token0,
        address token1,
        uint24 fee,
        uint128 initLiq,
        uint160 sqrtPriceX96
    ) public returns (uint256 idx, address pool) {
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }
        idx = pools.length;
        pool = factory.createPool(token0, token1, fee);
        pools.push(pool);
        poolToken0s.push(token0);
        poolToken1s.push(token1);

        UniswapV3Pool(pool).initialize(sqrtPriceX96);
        int24 spacing = UniswapV3Pool(pool).tickSpacing();
        addPoolLiq(idx, (TickMath.MIN_TICK / spacing) * spacing, (TickMath.MAX_TICK / spacing) * spacing, initLiq);
    }

    function addPoolLiq(uint256 index, int24 low, int24 high, uint128 amount) public {
        if (amount == 0) return;
        _idx = index;
        address pool = pools[index];
        UniswapV3Pool(pool).mint(address(this), low, high, amount, "");
        _idx = 0;
    }

    function removePoolLiq(uint256 index, int24 low, int24 high, uint128 amount) public {
        _idx = index;
        address pool = pools[index];
        UniswapV3Pool(pool).burn(low, high, amount);
        _idx = 0;
    }

    // Swap an amount in the pool.
    function swap(uint256 index, int256 amount, bool zeroForOne) public {
        _idx = index;
        address pool = pools[index];
        UniswapV3Pool(pool).swap(address(this), zeroForOne, amount, zeroForOne ? 0 : type(uint160).max, "");
        _idx = 0;
    }

    // Swap the pool to a certain price.
    function swapTo(uint256 index, uint160 targetPriceX96) public {
        _idx = index;
        address pool = pools[index];
        (uint160 currentPX96, , , , , , ) = UniswapV3Pool(pool).slot0();
        if (currentPX96 < targetPriceX96) {
            UniswapV3Pool(pool).swap(address(this), false, type(int256).max, targetPriceX96, "");
        } else {
            UniswapV3Pool(pool).swap(address(this), true, type(int256).max, targetPriceX96, "");
        }
        _idx = 0;
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external virtual{
        TransferHelper.safeTransfer(poolToken0s[_idx], msg.sender, amount0Owed);
        TransferHelper.safeTransfer(poolToken1s[_idx], msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            TransferHelper.safeTransfer(poolToken0s[_idx], msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            TransferHelper.safeTransfer(poolToken1s[_idx], msg.sender, uint256(amount1Delta));
        }
    }
}
