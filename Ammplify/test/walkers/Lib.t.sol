// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { console2 as console } from "forge-std/console2.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { Data, DataImpl } from "../../src/walkers/Data.sol";
import { Pool, PoolInfo, PoolLib } from "../../src/Pool.sol";
import { UniV3IntegrationSetup } from "../UniV3.u.sol";
import { Asset, AssetLib } from "../../src/Asset.sol";
import { TreeTickLib } from "../../src/tree/Tick.sol";
import { WalkerLib } from "../../src/walkers/Lib.sol";
import { PoolWalker } from "../../src/walkers/Pool.sol";
import { FeeLib } from "../../src/Fee.sol";

contract WalkerLibTest is Test, UniV3IntegrationSetup {
    WalkerFailProxy public failContract;

    function setUp() public {
        FeeLib.init();
        setUpPool(500); // For a tick spacing of 10.

        MockERC20(poolToken0s[0]).mint(address(this), 1e24);
        MockERC20(poolToken1s[0]).mint(address(this), 1e24);

        failContract = new WalkerFailProxy();
    }

    function testWalksWork() public {
        // Generic data setup.
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        console.log("compounding");
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, true);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1e24);
        WalkerLib.modify(pInfo, -100, 100, data);

        // Settle the positions for realism (later walks will try to collect expecting a position to be there).
        PoolWalker.settle(pInfo, -100, 100, data);

        console.log("non-compounding");
        (asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, false);
        data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1e24);
        WalkerLib.modify(pInfo, -100, 100, data);
        PoolWalker.settle(pInfo, -100, 100, data);

        console.log("taker");
        (asset, ) = AssetLib.newTaker(msg.sender, pInfo, -50, 50, 1e24, 0, 0);
        data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1e23);
        WalkerLib.modify(pInfo, -50, 50, data);
        PoolWalker.settle(pInfo, -100, 100, data);
    }

    function testEmptyNCWalk() public {
        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newMaker(msg.sender, pInfo, -100, 100, 1e24, false);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1e24);
        WalkerLib.modify(pInfo, -100, 100, data);
    }

    function testEmptyTakerFails() public {
        vm.expectRevert();
        failContract.runEmptyTakerFails();
    }
}

contract WalkerFailProxy is UniV3IntegrationSetup {
    function runEmptyTakerFails() public {
        FeeLib.init();
        setUpPool(500); // For a tick spacing of 10.
        MockERC20(poolToken0s[0]).mint(address(this), 1e24);
        MockERC20(poolToken1s[0]).mint(address(this), 1e24);

        PoolInfo memory pInfo = PoolLib.getPoolInfo(pools[0]);
        (Asset storage asset, ) = AssetLib.newTaker(msg.sender, pInfo, -50, 50, 1e24, 0, 0);
        Data memory data = DataImpl.make(pInfo, asset, 0, type(uint160).max, 1e23);
        WalkerLib.modify(pInfo, -50, 50, data);
    }
}
