// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { AdminLib } from "Commons/Util/Admin.sol";
import { AmmplifyAdminRights } from "./Admin.sol";
import { ReentrancyGuardTransient } from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { SafeCast } from "Commons/Math/Cast.sol";
import { RFTLib } from "Commons/Util/RFT.sol";
import { Store } from "../Store.sol";
import { PoolInfo, PoolLib } from "../Pool.sol";
import { Asset, AssetLib } from "../Asset.sol";
import { Data, DataImpl } from "../walkers/Data.sol";
import { WalkerLib } from "../walkers/Lib.sol";
import { PoolWalker } from "../walkers/Pool.sol";
import { VaultLib } from "../vaults/Vault.sol";
import { LiqType } from "../walkers/Liq.sol";

uint256 constant TAKER_VAULT_ID = 80085;

contract TakerFacet is ReentrancyGuardTransient {
    // Higher requirement than makers.
    uint128 public constant MIN_TAKER_LIQUIDITY = 1e12;

    error NotTakerOwner(address owner, address sender);
    error NotTaker(uint256 assetId);
    error DeMinimusTaker(uint128 liq);

    /// Our takers are permissioned, but anyone can collateralize for them.
    function collateralize(
        address recipient,
        address token,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        int256[] memory balances = new int256[](1);
        balances[0] = SafeCast.toInt256(amount);
        RFTLib.settle(msg.sender, tokens, balances, data);
        Store.fees().collateral[recipient][token] += amount;
    }

    function withdrawCollateral(
        address recipient,
        address token,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant {
        AdminLib.validateRights(AmmplifyAdminRights.TAKER);
        Store.fees().collateral[msg.sender][token] -= amount;
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        int256[] memory balances = new int256[](1);
        balances[0] = -SafeCast.toInt256(amount);
        RFTLib.settle(recipient, tokens, balances, data);
    }

    function newTaker(
        address recipient,
        address poolAddr,
        int24[2] calldata ticks,
        uint128 liq,
        uint8[2] calldata vaultIndices,
        uint160[2] calldata sqrtPriceLimitsX96,
        uint160 freezeSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (uint256 _assetId) {
        if (liq < MIN_TAKER_LIQUIDITY) revert DeMinimusTaker(liq);
        AdminLib.validateRights(AmmplifyAdminRights.TAKER);
        PoolInfo memory pInfo = PoolLib.getPoolInfo(poolAddr);
        (Asset storage asset, uint256 assetId) = AssetLib.newTaker(
            recipient,
            pInfo,
            ticks[0],
            ticks[1],
            liq,
            vaultIndices[0],
            vaultIndices[1]
        );
        Data memory data = DataImpl.make(pInfo, asset, sqrtPriceLimitsX96[0], sqrtPriceLimitsX96[1], liq);
        // This fills in the nodes in the asset.
        WalkerLib.modify(pInfo, ticks[0], ticks[1], data);
        // First we withdraw the liquidity.
        PoolWalker.settle(pInfo, ticks[0], ticks[1], data);
        // The walked balances are the borrowed balances, we swap them to either amount.
        // The walked balances will be negative since they're giving it to the user.
        address[] memory tokens = pInfo.tokens();
        int256[] memory balances = new int256[](2);
        balances[0] = data.xBalance;
        balances[1] = data.yBalance;
        (uint256 xFreeze, uint256 yFreeze) = PoolLib.getAmounts(freezeSqrtPriceX96, ticks[0], ticks[1], liq, true);
        balances[0] += SafeCast.toInt256(xFreeze);
        balances[1] += SafeCast.toInt256(yFreeze);
        RFTLib.settle(msg.sender, tokens, balances, rftData);
        VaultLib.deposit(tokens[0], vaultIndices[0], assetId, xFreeze);
        VaultLib.deposit(tokens[1], vaultIndices[1], assetId, yFreeze);
        return assetId;
    }

    /// @dev There is not recipient here because RFTLib doesn't support that yet.
    function removeTaker(
        uint256 assetId,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (address token0, address token1, int256 balance0, int256 balance1) {
        Asset storage asset = AssetLib.getAsset(assetId);
        require(asset.owner == msg.sender, NotTakerOwner(asset.owner, msg.sender));
        require(asset.liqType == LiqType.TAKER, NotTaker(assetId));
        PoolInfo memory pInfo = PoolLib.getPoolInfo(asset.poolAddr);
        Data memory data = DataImpl.make(pInfo, asset, minSqrtPriceX96, maxSqrtPriceX96, 0);
        WalkerLib.modify(pInfo, asset.lowTick, asset.highTick, data);
        address[] memory tokens = pInfo.tokens();
        int256[] memory balances = new int256[](2);
        balances[0] = data.xBalance;
        balances[1] = data.yBalance;
        balances[0] -= SafeCast.toInt256(VaultLib.withdraw(tokens[0], asset.xVaultIndex, assetId));
        balances[1] -= SafeCast.toInt256(VaultLib.withdraw(tokens[1], asset.yVaultIndex, assetId));
        balance0 = -balances[0];
        balance1 = -balances[1];
        // Closing pays up the fees and leave the collateral alone. The collateral is really just there
        // to make sure while the position is open you can cover the fees. So there's really no need to keep
        // depositing and withdrawing collateral if your opened size stays roughly the same.
        RFTLib.settle(msg.sender, tokens, balances, rftData);
        // Finally we deposit the assets.
        PoolWalker.settle(pInfo, asset.lowTick, asset.highTick, data);
        AssetLib.removeAsset(assetId);
        // Return values
        token0 = tokens[0];
        token1 = tokens[1];
    }
}
