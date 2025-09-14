// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Node } from "../walkers/Node.sol";
import { Key } from "../tree/Key.sol";
import { PoolInfo } from "../Pool.sol";
import { LiqType } from "../walkers/Liq.sol";

interface IView {
    // Errors
    error LengthMismatch(uint256 baseLength, uint256 widthLength);

    /// @notice Get basic information about a pool.
    /// @param poolAddr The address of the pool.
    /// @return pInfo The pool information.
    function getPoolInfo(address poolAddr) external view returns (PoolInfo memory pInfo);

    /// @notice Get basic asset info and then use the appropriate view function in the appropriate facet
    /// to get more details.
    /// @param assetId The ID of the asset.
    /// @return owner The owner of the asset.
    /// @return poolAddr The address of the pool.
    /// @return lowTick The lower tick of the asset.
    /// @return highTick The upper tick of the asset.
    /// @return liqType The liquidity type of the asset.
    /// @return liq The liquidity amount of the asset.
    function getAssetInfo(
        uint256 assetId
    )
        external
        view
        returns (address owner, address poolAddr, int24 lowTick, int24 highTick, LiqType liqType, uint128 liq);

    /// @notice Get information about nodes in the pool.
    /// @dev You probably need to query the poolInfo first to get the treeWidth to compute valid keys
    /// first.
    /// @param poolAddr The address of the pool.
    /// @param keys The keys of the nodes to query.
    /// @return node The node information.
    function getNodes(address poolAddr, Key[] calldata keys) external view returns (Node[] memory node);

    /// @notice Compute the token balances owned/owed by the position.
    /// @dev We separate the fee and liq balance so we can use the same method for fee earnings and
    /// total value.
    /// @param assetId The ID of the asset.
    /// @return netBalance0 The amount of token0 owed to the position owner sans fees
    /// (Negative is owed by the owner).
    /// @return netBalance1 The amount of token1 owed to the position owner sans fees
    /// (Negative is owed by the owner).
    /// @return fees0 The amount of fees in token0 owed to a maker or owed by a taker
    /// depending on the liq type.
    /// @return fees1 The amount of fees in token1 owed to a maker or owed by a taker
    /// depending on the liq type.
    function queryAssetBalances(
        uint256 assetId
    ) external view returns (int256 netBalance0, int256 netBalance1, uint256 fees0, uint256 fees1);
}
