// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { Data, DataImpl } from "../../src/walkers/Data.sol";
import { Key, KeyImpl } from "../../src/tree/Key.sol";
import { Pool, PoolInfo, PoolLib } from "../../src/Pool.sol";
import { UniV3IntegrationSetup } from "../UniV3.u.sol";
import { Asset, AssetLib } from "../../src/Asset.sol";
import { Store } from "../../src/Store.sol";
import { Node } from "../../src/walkers/Node.sol";
import { TreeTickLib } from "../../src/tree/Tick.sol";
import { PoolWalker } from "../../src/walkers/Pool.sol";
import { IUniswapV3Pool } from "v3-core/interfaces/IUniswapV3Pool.sol";

contract PoolWalkerTest is Test, UniV3IntegrationSetup {
    Node public node;

    function setUp() public {
        setUpPool(500); // For a tick spacing of 10.

        MockERC20(poolToken0s[0]).mint(address(this), 1e24);
        MockERC20(poolToken1s[0]).mint(address(this), 1e24);
    }

    function testUpdateLiq() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1);
        // Check the pool's current liquidity for this key.
        Key key = KeyImpl.make(6400, 1600);
        (int24 lowTick, int24 highTick) = key.ticks(data.fees.rootWidth, data.fees.tickSpacing);
        bytes32 posKey = keccak256(abi.encodePacked(address(this), lowTick, highTick));
        (uint128 liq, , , , ) = IUniswapV3Pool(pools[0]).positions(posKey);
        assertEq(liq, 0);

        node.liq.mLiq = 100e8;
        PoolWalker.updateLiq(key, node, data);
        (liq, , , , ) = IUniswapV3Pool(pools[0]).positions(posKey);
        assertEq(liq, 100e8);

        // Check that the pool's liquidity has been updated.
        node.liq.mLiq = 50e8;
        PoolWalker.updateLiq(key, node, data);
        (liq, , , , ) = IUniswapV3Pool(pools[0]).positions(posKey);
        assertEq(liq, 50e8);

        node.liq.borrowed = 200e8;
        PoolWalker.updateLiq(key, node, data);
        (liq, , , , ) = IUniswapV3Pool(pools[0]).positions(posKey);
        assertEq(liq, 250e8);
    }
}
