// SPDX-License-Identifier: BUSL-1.1-or-later
pragma solidity ^0.8.27;

import { IUniswapV3MintCallback } from "v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { TransferHelper } from "Commons/Util/TransferHelper.sol";
import { PoolInfo, PoolLib } from "../Pool.sol";

contract PoolFacet is IUniswapV3MintCallback {
    error UnauthorizedMint(address expected, address actual);

    /// @notice Called to `msg.sender` after minting liquidity to a position from IUniswapV3Pool#mint.
    /// @dev In the implementation you must pay the pool tokens owed for the minted liquidity.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
    /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        address activeMint = PoolLib.poolGuard();
        require(msg.sender == activeMint, UnauthorizedMint(activeMint, msg.sender));
        PoolInfo memory pInfo = PoolLib.getPoolInfo(activeMint);
        TransferHelper.safeTransfer(pInfo.token0, activeMint, amount0Owed);
        TransferHelper.safeTransfer(pInfo.token1, activeMint, amount1Owed);
    }
}
