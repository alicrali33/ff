// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Data, DataImpl } from "../../src/walkers/Data.sol";
import { Key, KeyImpl } from "../../src/tree/Key.sol";
import { Pool, PoolInfo, PoolLib } from "../../src/Pool.sol";
import { UniV3IntegrationSetup } from "../UniV3.u.sol";
import { Asset, AssetLib } from "../../src/Asset.sol";
import { Store } from "../../src/Store.sol";
import { TreeTickLib } from "../../src/tree/Tick.sol";

contract DataTest is Test, UniV3IntegrationSetup {
    function setUp() public {
        setUpPool(500); // For a tick spacing of 10.
    }

    function testMake() public {
        Pool storage p = Store.pool(pools[0]);
        p.timestamp = 1;
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        // Setup done.
        Data memory data = DataImpl.make(pInfo, asset, 0, 2 << 96, 1);
        // We can't really test this here because of how foundry works with expecting reverts.
        // So we'll have to test it in the higher level integration tests.
        // vm.expectRevert(abi.encodeWithSelector(DataImpl.PriceSlippageExceeded.selector, 1 << 96, 2 << 96, 3 << 96));
        // DataImpl.make(pInfo, asset, 2 << 96, 3 << 96, 1);
        // Is pool info correct?
        assertEq(data.poolAddr, pInfo.poolAddr);
        bytes32 poolStore = data.poolStore;
        assembly {
            p.slot := poolStore
        }
        assertEq(p.timestamp, 1);
        assertEq(data.sqrtPriceX96, 1 << 96);
        assertEq(data.timestamp, 1);
    }

    function testComputeBorrows() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, 2 << 96, 1);
        uint24 base = TreeTickLib.tickToTreeIndex(100, data.fees.rootWidth, data.fees.tickSpacing);
        Key key = KeyImpl.make(base, 16);
        (uint256 x, uint256 y) = data.computeBorrows(key, 100e18, false);
        // Pool price changes don't affect borrow amount.
        swapTo(0, 4 << 96);
        (uint256 x2, uint256 y2) = data.computeBorrows(key, 100e18, false);
        assertEq(x, x2, "x2");
        assertEq(y, y2, "y2");
        (x2, y2) = data.computeBorrows(key, 200e18, false);
        // Roughly doubles the amount.
        assertApproxEqAbs(x * 2, x2, 1, "x22");
        assertApproxEqAbs(y * 2, y2, 1, "y22");
        // Doubling the with should also double the amounts (roughly).
        base = TreeTickLib.tickToTreeIndex(20, data.fees.rootWidth, data.fees.tickSpacing);
        key = KeyImpl.make(base, 32);
        (x2, y2) = data.computeBorrows(key, 100e18, false);
        assertApproxEqRel(x * 2, x2, 1e16, "x222");
        assertApproxEqRel(y * 2, y2, 1e16, "y222");
    }

    function testComputeBalances() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, 2 << 96, 1);
        uint24 base = TreeTickLib.tickToTreeIndex(-640, data.fees.rootWidth, data.fees.tickSpacing);
        Key key = KeyImpl.make(base, 128);
        // This is centered around 0, so the current balances and the borrows will match.
        (uint256 bx, uint256 by) = data.computeBorrows(key, 100e18, false);
        (uint256 x, uint256 y) = data.computeBalances(key, 100e18, false);
        assertEq(bx, x, "bx");
        assertEq(by, y, "by");
        assertNotEq(x, 0, "x0");
        assertNotEq(y, 0, "y0");
        // But if the price moves this isn't true anymore.
        data.sqrtPriceX96 = 4 << 96;
        (uint256 x2, uint256 y2) = data.computeBalances(key, 100e18, false);
        assertNotEq(x, x2, "x8");
        assertNotEq(y, y2, "y8");
    }
}
