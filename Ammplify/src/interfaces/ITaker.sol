// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

interface ITaker {
    // Errors
    error NotTakerOwner(address owner, address sender);
    error NotTaker(uint256 assetId);

    /// @notice Collateralizes a taker position.
    /// @param recipient The recipient of the collateral.
    /// @param token The token to collateralize.
    /// @param amount The amount to collateralize.
    /// @param data Additional data for the operation.
    function collateralize(address recipient, address token, uint256 amount, bytes calldata data) external;

    /// @notice Withdraws collateral from a taker position.
    /// @param recipient The recipient of the withdrawn collateral.
    /// @param token The token to withdraw.
    /// @param amount The amount to withdraw.
    /// @param data Additional data for the operation.
    function withdrawCollateral(address recipient, address token, uint256 amount, bytes calldata data) external;

    /// @notice Creates a new taker position.
    /// @param recipient The recipient of the taker position.
    /// @param poolAddr The address of the pool.
    /// @param ticks The tick range for the position.
    /// @param liq The amount of liquidity to provide.
    /// @param vaultIndices The vault indices for the position.
    /// @param sqrtPriceLimitsX96 The sqrt price limits for the operation.
    /// @param freezeSqrtPriceX96 The freeze sqrt price for the position.
    /// @param rftData Data passed during RFT to the payer.
    function newTaker(
        address recipient,
        address poolAddr,
        int24[2] calldata ticks,
        uint128 liq,
        uint8[2] calldata vaultIndices,
        uint160[2] calldata sqrtPriceLimitsX96,
        uint160 freezeSqrtPriceX96,
        bytes calldata rftData
    ) external returns (uint256 _assetId);

    /// @notice Removes a taker position.
    /// @param assetId The ID of the asset to remove.
    /// @param minSqrtPriceX96 The minimum sqrt price for the operation.
    /// @param maxSqrtPriceX96 The maximum sqrt price for the operation.
    /// @param rftData Data passed during RFT to the recipient.
    function removeTaker(
        uint256 assetId,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external returns (address token0, address token1, int256 balance0, int256 balance1);
}
