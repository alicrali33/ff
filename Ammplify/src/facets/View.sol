// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Node } from "../walkers/Node.sol";
import { Key, KeyImpl } from "../tree/Key.sol";
import { Store } from "../Store.sol";
import { PoolInfo, PoolLib, Pool } from "../Pool.sol";
import { LiqType } from "../walkers/Liq.sol";
import { Asset, AssetLib } from "../Asset.sol";
import { VaultLib } from "../vaults/Vault.sol";
import { ViewData, ViewDataImpl } from "../walkers/View.sol";
import { ViewWalkerLib } from "../walkers/Lib.sol";

/// Query the values of internal data structures.
contract ViewFacet {
    error LengthMismatch(uint256 baseLength, uint256 widthLength);

    /// Get basic information about a pool.
    function getPoolInfo(address poolAddr) external view returns (PoolInfo memory pInfo) {
        pInfo = PoolLib.getPoolInfo(poolAddr);
    }

    /// Get basic asset info and then use the appropriate view function in the appropriate facet to get more details.
    function getAssetInfo(
        uint256 assetId
    )
        external
        view
        returns (address owner, address poolAddr, int24 lowTick, int24 highTick, LiqType liqType, uint128 liq)
    {
        Asset storage asset = AssetLib.getAsset(assetId);
        return (asset.owner, asset.poolAddr, asset.lowTick, asset.highTick, asset.liqType, asset.liq);
    }

    /// Get information about nodes in the pool.
    /// @dev You probably need to query the poolInfo first to get the treeWidth to compute valid keys first.
    function getNodes(address poolAddr, Key[] calldata keys) external view returns (Node[] memory node) {
        Pool storage pool = Store.pool(poolAddr);
        node = new Node[](keys.length);

        for (uint256 i = 0; i < keys.length; i++) {
            Key key = keys[i];
            node[i] = pool.nodes[key];
        }
    }

    /// Get the collateral balance for a specific recipient and token.
    /// @param recipient The address of the collateral owner
    /// @param token The address of the token
    /// @return The amount of collateral deposited by the recipient for the specified token
    function getCollateralBalance(address recipient, address token) external view returns (uint256) {
        return Store.fees().collateral[recipient][token];
    }

    /// Get collateral balances for multiple recipients and tokens.
    /// @param recipients Array of recipient addresses
    /// @param tokens Array of token addresses (must be same length as recipients)
    /// @return Array of collateral balances corresponding to each recipient-token pair
    function getCollateralBalances(
        address[] calldata recipients,
        address[] calldata tokens
    ) external view returns (uint256[] memory) {
        if (recipients.length != tokens.length) {
            revert LengthMismatch(recipients.length, tokens.length);
        }

        uint256[] memory balances = new uint256[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            balances[i] = Store.fees().collateral[recipients[i]][tokens[i]];
        }
        return balances;
    }

    /// Compute the token balances owned/owed by the position.
    /// @dev We separate the fee and liq balance so we can use the same method for fee earnings and total value.
    /// @return netBalance0 The amount of token0 owed to the position owner sans fees (Negative is owed by the owner).
    /// @return netBalance1 The amount of token1 owed to the position owner sans fees (Negative is owed by the owner).
    /// @return fees0 The amount of fees in token0 owed to a maker or owed by a taker depending on the liq type.
    /// @return fees1 The amount of fees in token1 owed to a maker or owed by a taker depending on the liq type.
    function queryAssetBalances(
        uint256 assetId
    ) external view returns (int256 netBalance0, int256 netBalance1, uint256 fees0, uint256 fees1) {
        Asset storage asset = AssetLib.getAsset(assetId);
        PoolInfo memory pInfo = PoolLib.getPoolInfo(asset.poolAddr);
        ViewData memory data = ViewDataImpl.make(pInfo, asset);
        ViewWalkerLib.viewAsset(pInfo, asset.lowTick, asset.highTick, data);
        if (asset.liqType == LiqType.TAKER) {
            uint256 vaultX = VaultLib.balanceOf(pInfo.token0, asset.xVaultIndex, assetId, false);
            uint256 vaultY = VaultLib.balanceOf(pInfo.token1, asset.yVaultIndex, assetId, false);
            // Balance and fees are owed, and vault balance is owned.
            netBalance0 = int256(vaultX) - int256(data.liqBalanceX);
            netBalance1 = int256(vaultY) - int256(data.liqBalanceY);
            fees0 = data.earningsX;
            fees1 = data.earningsY;
        } else {
            netBalance0 = int256(data.liqBalanceX);
            netBalance1 = int256(data.liqBalanceY);
            fees0 = data.earningsX;
            fees1 = data.earningsY;
        }
    }
}
