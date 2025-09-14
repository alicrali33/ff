// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { PoolInfo, PoolLib } from "./Pool.sol";
import { Key } from "./tree/Key.sol";
import { LiqType } from "./walkers/Liq.sol";
import { Store } from "./Store.sol";

struct Asset {
    address owner;
    /* pool info */
    address poolAddr;
    /* Position summary */
    int24 lowTick;
    int24 highTick;
    LiqType liqType;
    uint8 xVaultIndex;
    uint8 yVaultIndex;
    uint128 liq; // The original liquidity of the asset.
    uint128 timestamp; // The timestamp of when the asset was last modified.
    /* node info */
    mapping(Key => AssetNode) nodes;
}

struct AssetNode {
    uint128 sliq; // The share/liq of the node we own.
    // For takers, this is a checkpoint of the per liq fees owed.
    // For NC makers, this is a checkpoint of the per liq fees earned.
    // For C makers, this is not used.
    // These checkpoints include both the swap fees and the reservation fees.
    uint256 fee0CheckX128;
    uint256 fee1CheckX128;
}

struct AssetStore {
    mapping(address owner => uint256[] assetIds) ownerAssets;
    mapping(uint256 assetId => Asset) assets;
    uint256 nextAssetId;
}

library AssetLib {
    // We limit the number of assets per owner to prevent someone from blocking removes by overloading gas
    // costs by donating positions to other users.
    uint8 public constant MAX_ASSETS_PER_OWNER = 16;

    error NoRecipient();
    error ExcessiveAssetsPerOwner(uint256 count);
    error AssetNotFound(uint256 assetId);

    /// Create a new maker asset.
    function newMaker(
        address recipient,
        PoolInfo memory pInfo,
        int24 lowTick,
        int24 highTick,
        uint128 liq,
        bool isCompounding
    ) internal returns (Asset storage asset, uint256 assetId) {
        // address 0x0 is a valid recipient for maker assets.

        AssetStore storage store = Store.assets();
        assetId = ++store.nextAssetId;
        asset = store.assets[assetId];
        asset.owner = recipient;
        asset.poolAddr = pInfo.poolAddr;
        asset.lowTick = lowTick;
        asset.highTick = highTick;
        asset.liqType = isCompounding ? LiqType.MAKER : LiqType.MAKER_NC;
        asset.liq = liq;
        updateTimestamp(asset);
        // The Nodes are to be filled in by a walker.
        // Add the asset to the owner's bookkeeping.
        addAssetToOwner(store, assetId, recipient);
    }

    /// Create a new taker asset.
    function newTaker(
        address recipient,
        PoolInfo memory pInfo,
        int24 lowTick,
        int24 highTick,
        uint128 liq,
        uint8 xVaultIndex,
        uint8 yVaultIndex
    ) internal returns (Asset storage asset, uint256 assetId) {
        require(recipient != address(0x0), NoRecipient());

        AssetStore storage store = Store.assets();
        assetId = ++store.nextAssetId;
        asset = store.assets[assetId];
        asset.owner = recipient;
        asset.poolAddr = pInfo.poolAddr;
        asset.lowTick = lowTick;
        asset.highTick = highTick;
        asset.liqType = LiqType.TAKER;
        asset.liq = liq;
        asset.xVaultIndex = xVaultIndex;
        asset.yVaultIndex = yVaultIndex;
        updateTimestamp(asset);
        // The Nodes are to be filled in by a walker.
        addAssetToOwner(store, assetId, recipient);
    }

    /// Fetch an asset by ID (typically for viewing).
    function getAsset(uint256 assetId) internal view returns (Asset storage asset) {
        AssetStore storage store = Store.assets();
        asset = store.assets[assetId];
        require(asset.owner != address(0x0), AssetNotFound(assetId));
    }

    /// Remove an asset.
    function removeAsset(uint256 assetId) internal {
        AssetStore storage store = Store.assets();
        Asset storage asset = store.assets[assetId];
        address owner = asset.owner;
        // The asset nodes will have been removed by the walker.
        delete store.assets[assetId];
        uint256[] storage ownerAssets = store.ownerAssets[owner];
        bool found = false;
        for (uint8 i = 0; i < ownerAssets.length; i++) {
            if (ownerAssets[i] == assetId) {
                ownerAssets[i] = ownerAssets[ownerAssets.length - 1];
                ownerAssets.pop();
                found = true;
                break;
            }
        }
        require(found, AssetNotFound(assetId));
    }

    /// Update the timestamp of when the asset was last modified.
    /// @dev This is for calculating JIT penalties.
    function updateTimestamp(Asset storage asset) internal {
        asset.timestamp = uint128(block.timestamp);
    }

    /* Helpers */

    function addAssetToOwner(AssetStore storage store, uint256 assetId, address owner) private {
        require(
            store.ownerAssets[owner].length < MAX_ASSETS_PER_OWNER,
            ExcessiveAssetsPerOwner(store.ownerAssets[owner].length)
        );
        store.ownerAssets[owner].push(assetId);
    }
}
