// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { Asset, AssetStore, AssetLib } from "../src/Asset.sol";
import { PoolInfo } from "../src/Pool.sol";
import { Store } from "../src/Store.sol";
import { LiqType } from "../src/walkers/Liq.sol";

contract AssetTest is Test {
    function testNewMaker() public {
        assertEq(Store.assets().nextAssetId, 0, "AssetStore.nextAssetId.default");

        address owner = makeAddr("cOwner");

        // create maker not compounding
        PoolInfo memory pInfoNC;
        pInfoNC.poolAddr = makeAddr("ncPool");

        vm.warp(100);

        (Asset storage assetNC, uint256 assetIdNC) = AssetLib.newMaker(owner, pInfoNC, -2000, 2000, 1e20, false);

        assertEq(assetIdNC, 1, "assetIdNC");

        assertEq(assetNC.owner, owner, "assetNC.owner");
        assertEq(assetNC.poolAddr, pInfoNC.poolAddr, "assetNC.poolAddr");
        assertEq(assetNC.lowTick, -2000, "assetNC.lowTick");
        assertEq(assetNC.highTick, 2000, "assetNC.highTick");
        assertEq(uint8(assetNC.liqType), uint8(LiqType.MAKER_NC), "assetNC.liqType");
        assertEq(assetNC.liq, 1e20, "assetNC.liq");
        assertEq(assetNC.timestamp, 100, "assetNC.timestamp");

        // confirm in store
        Asset storage storedAsset = Store.assets().assets[assetIdNC];
        assertEq(storedAsset.owner, assetNC.owner, "storedAssetNC.owner");
        assertEq(storedAsset.poolAddr, assetNC.poolAddr, "storedAssetNC.poolAddr");
        assertEq(storedAsset.lowTick, assetNC.lowTick, "storedAssetNC.lowTick");
        assertEq(storedAsset.highTick, assetNC.highTick, "storedAssetNC.highTick");
        assertEq(uint8(storedAsset.liqType), uint8(assetNC.liqType), "storedAssetNC.liqType");
        assertEq(storedAsset.liq, assetNC.liq, "storedAssetNC.liq");
        assertEq(storedAsset.timestamp, assetNC.timestamp, "storedAssetNC.timestamp");

        // create maker compounding
        PoolInfo memory pInfoC;
        pInfoC.poolAddr = makeAddr("cPool");

        vm.warp(200);

        (Asset storage assetC, uint256 assetIdC) = AssetLib.newMaker(owner, pInfoC, -3000, 4000, 2e21, true);
        assertEq(assetIdC, 2, "assetIdC");

        assertEq(assetC.owner, owner, "assetC.owner");
        assertEq(assetC.poolAddr, pInfoC.poolAddr, "assetC.poolAddr");
        assertEq(assetC.lowTick, -3000, "assetC.lowTick");
        assertEq(assetC.highTick, 4000, "assetC.highTick");
        assertEq(uint8(assetC.liqType), uint8(LiqType.MAKER), "assetC.liqType");
        assertEq(assetC.liq, 2e21, "assetC.liq");
        assertEq(assetC.timestamp, 200, "assetC.timestamp");

        // confirm in store
        Asset storage storedAssetC = Store.assets().assets[assetIdC];
        assertEq(storedAssetC.owner, assetC.owner, "storedAssetC.owner");
        assertEq(storedAssetC.poolAddr, assetC.poolAddr, "storedAssetC.poolAddr");
        assertEq(storedAssetC.lowTick, assetC.lowTick, "storedAssetC.lowTick");
        assertEq(storedAssetC.highTick, assetC.highTick, "storedAssetC.highTick");
        assertEq(uint8(storedAssetC.liqType), uint8(assetC.liqType), "storedAssetC.liqType");
        assertEq(storedAssetC.liq, assetC.liq, "storedAssetC.liq");
        assertEq(storedAssetC.timestamp, assetC.timestamp, "storedAssetC.timestamp");

        // confirm ownership in store (addAssetToOwner)
        uint256[] storage ownerAssets = Store.assets().ownerAssets[owner];
        assertEq(ownerAssets.length, 2, "ownerAssets.length");
        assertEq(ownerAssets[0], assetIdNC, "ownerAssets[0].NC");
        assertEq(ownerAssets[1], assetIdC, "ownerAssets[1].C");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertNewMakerMaxAssets() public {
        address owner = makeAddr("owner");

        PoolInfo memory pInfo;
        pInfo.poolAddr = makeAddr("pool");

        for (uint256 i = 0; i < AssetLib.MAX_ASSETS_PER_OWNER; i++) {
            AssetLib.newMaker(owner, pInfo, -2000, -2000, 1e20, false);
        }

        vm.expectRevert(
            abi.encodeWithSelector(AssetLib.ExcessiveAssetsPerOwner.selector, AssetLib.MAX_ASSETS_PER_OWNER)
        );
        AssetLib.newMaker(owner, pInfo, -2000, -2000, 1e20, false);
    }

    function testNewTaker() public {
        assertEq(Store.assets().nextAssetId, 0, "AssetStore.nextAssetId.default");

        address owner = makeAddr("owner");

        PoolInfo memory pInfo;
        pInfo.poolAddr = makeAddr("pool");

        // create taker
        vm.warp(100);
        (Asset storage taker, uint256 takerId) = AssetLib.newTaker(owner, pInfo, -2000, 2000, 1e20, 2, 3);

        assertEq(takerId, 1, "takerId");

        assertEq(taker.owner, owner, "taker.owner");
        assertEq(taker.poolAddr, pInfo.poolAddr, "taker.poolAddr");
        assertEq(taker.lowTick, -2000, "taker.lowTick");
        assertEq(taker.highTick, 2000, "taker.highTick");
        assertEq(uint8(taker.liqType), uint8(LiqType.TAKER), "taker.liqType");
        assertEq(taker.liq, 1e20, "taker.liq");
        assertEq(taker.xVaultIndex, 2, "taker.xVaultIndex");
        assertEq(taker.yVaultIndex, 3, "taker.yVaultIndex");
        assertEq(taker.timestamp, 100, "taker.timestamp");

        // confirm in store
        Asset storage storedTaker = Store.assets().assets[takerId];
        assertEq(storedTaker.owner, taker.owner, "storedTaker.owner");
        assertEq(storedTaker.poolAddr, taker.poolAddr, "storedTaker.poolAddr");
        assertEq(storedTaker.lowTick, taker.lowTick, "storedTaker.lowTick");
        assertEq(storedTaker.highTick, taker.highTick, "storedTaker.highTick");
        assertEq(uint8(storedTaker.liqType), uint8(taker.liqType), "storedTaker.liqType");
        assertEq(storedTaker.liq, taker.liq, "storedTaker.liq");
        assertEq(storedTaker.xVaultIndex, taker.xVaultIndex, "storedTaker.xVaultIndex");
        assertEq(storedTaker.yVaultIndex, taker.yVaultIndex, "storedTaker.yVaultIndex");
        assertEq(storedTaker.timestamp, taker.timestamp, "storedTaker.timestamp");

        // add another taker
        (, uint256 takerId2) = AssetLib.newTaker(owner, pInfo, -2000, 2000, 1e20, 2, 3);

        // confirm ownership in store (addAssetToOwner)
        uint256[] storage ownerAssets = Store.assets().ownerAssets[owner];
        assertEq(ownerAssets.length, 2, "ownerAssets.length");
        assertEq(ownerAssets[0], takerId, "ownerAssets[0].taker1");
        assertEq(ownerAssets[1], takerId2, "ownerAssets[1].taker2");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertNewTakerNoRecipient() public {
        PoolInfo memory pInfo;
        pInfo.poolAddr = makeAddr("pool");

        vm.expectRevert(abi.encodeWithSelector(AssetLib.NoRecipient.selector));
        AssetLib.newTaker(address(0x0), pInfo, -2000, -2000, 1e20, 0, 1);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertNewTakerMaxAssets() public {
        address owner = makeAddr("owner");

        PoolInfo memory pInfo;
        pInfo.poolAddr = makeAddr("pool");

        for (uint256 i = 0; i < AssetLib.MAX_ASSETS_PER_OWNER; i++) {
            AssetLib.newTaker(owner, pInfo, -2000, -2000, 1e20, 0, 1);
        }

        vm.expectRevert(
            abi.encodeWithSelector(AssetLib.ExcessiveAssetsPerOwner.selector, AssetLib.MAX_ASSETS_PER_OWNER)
        );
        AssetLib.newTaker(owner, pInfo, -2000, -2000, 1e20, 0, 1);
    }

    function testGetAsset() public {
        address owner = makeAddr("owner");

        PoolInfo memory pInfo;
        pInfo.poolAddr = makeAddr("pool");

        // maker
        (Asset storage maker, uint256 makerId) = AssetLib.newMaker(owner, pInfo, -2000, 2000, 1e20, false);

        Asset storage gMaker = AssetLib.getAsset(makerId);
        assertEq(gMaker.owner, maker.owner, "gMaker.owner");
        assertEq(gMaker.poolAddr, maker.poolAddr, "gMaker.poolAddr");
        assertEq(gMaker.lowTick, maker.lowTick, "gMaker.lowTick");
        assertEq(gMaker.highTick, maker.highTick, "gMaker.highTick");
        assertEq(uint8(gMaker.liqType), uint8(maker.liqType), "gMaker.liqType");
        assertEq(gMaker.liq, maker.liq, "gMaker.liq");
        assertEq(gMaker.timestamp, maker.timestamp, "gMaker.timestamp");

        // taker
        (Asset storage taker, uint256 takerId) = AssetLib.newMaker(owner, pInfo, -2000, 2000, 1e20, false);

        Asset storage gTaker = AssetLib.getAsset(takerId);
        assertEq(gTaker.owner, taker.owner, "gTaker.owner");
        assertEq(gTaker.poolAddr, taker.poolAddr, "gTaker.poolAddr");
        assertEq(gTaker.lowTick, taker.lowTick, "gTaker.lowTick");
        assertEq(gTaker.highTick, taker.highTick, "gTaker.highTick");
        assertEq(uint8(gTaker.liqType), uint8(taker.liqType), "gTaker.liqType");
        assertEq(gTaker.liq, taker.liq, "gTaker.liq");
        assertEq(gTaker.xVaultIndex, taker.xVaultIndex, "gTaker.xVaultIndex");
        assertEq(gTaker.yVaultIndex, taker.yVaultIndex, "gTaker.yVaultIndex");
        assertEq(gTaker.timestamp, taker.timestamp, "gTaker.timestamp");
    }

    function testRemoveAsset() public {
        address owner = makeAddr("owner");

        PoolInfo memory pInfo;
        pInfo.poolAddr = makeAddr("pool");

        (, uint256 assetId1) = AssetLib.newMaker(owner, pInfo, -2000, 2000, 1e20, false);
        (, uint256 assetId2) = AssetLib.newMaker(owner, pInfo, -2000, 2000, 1e20, false);
        (, uint256 assetId3) = AssetLib.newMaker(owner, pInfo, -2000, 2000, 1e20, false);

        // Remove middle
        AssetLib.removeAsset(assetId2);

        uint256[] storage ownerAssets = Store.assets().ownerAssets[owner];
        assertEq(ownerAssets.length, 2, "ownerAssets.length");
        assertEq(ownerAssets[0], assetId1, "ownerAssets[0].assetId1");
        assertEq(ownerAssets[1], assetId3, "ownerAssets[1].assetId3");

        // Remove end
        AssetLib.removeAsset(assetId3);

        ownerAssets = Store.assets().ownerAssets[owner];
        assertEq(ownerAssets.length, 1, "ownerAssets.length");
        assertEq(ownerAssets[0], assetId1, "ownerAssets[0].assetId1");

        // Remove first
        AssetLib.removeAsset(assetId1);

        ownerAssets = Store.assets().ownerAssets[owner];
        assertEq(ownerAssets.length, 0, "ownerAssets.length");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevertRemoveAssetNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(AssetLib.AssetNotFound.selector, 0));
        AssetLib.removeAsset(0);
    }

    function testUpdateTimestamp() public {
        // Fake an asset.
        Store.assets().assets[0].owner = address(this);
        // Check its default timestamp.
        Asset storage asset = AssetLib.getAsset(0);
        assertEq(asset.timestamp, 0, "asset.timestamp.default");

        vm.warp(100);
        AssetLib.updateTimestamp(asset);
        assertEq(asset.timestamp, 100, "asset.timestamp.updated1");

        vm.warp(200);
        AssetLib.updateTimestamp(asset);
        assertEq(asset.timestamp, 200, "asset.timestamp.updated2");
    }
}
