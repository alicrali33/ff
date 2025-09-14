// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { PoolInfo } from "../Pool.sol";
import { Asset, AssetLib } from "../Asset.sol";
import { LiqType } from "../walkers/Liq.sol";
import { Data, DataImpl } from "../walkers/Data.sol";
import { ReentrancyGuardTransient } from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { WalkerLib } from "../walkers/Lib.sol";
import { PoolLib } from "../Pool.sol";
import { PoolWalker } from "../walkers/Pool.sol";
import { RFTLib } from "Commons/Util/RFT.sol";
import { FeeLib } from "../Fee.sol";
import { IMaker } from "../interfaces/IMaker.sol";

contract MakerFacet is ReentrancyGuardTransient, IMaker {
    uint128 public constant MIN_MAKER_LIQUIDITY = 1e6;

    /// @inheritdoc IMaker
    function newMaker(
        address recipient,
        address poolAddr,
        int24 lowTick,
        int24 highTick,
        uint128 liq,
        bool isCompounding,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (uint256 _assetId) {
        require(liq >= MIN_MAKER_LIQUIDITY, DeMinimusMaker(liq));
        PoolInfo memory pInfo = PoolLib.getPoolInfo(poolAddr);
        (Asset storage asset, uint256 assetId) = AssetLib.newMaker(
            recipient,
            pInfo,
            lowTick,
            highTick,
            liq,
            isCompounding
        );
        Data memory data = DataImpl.make(pInfo, asset, minSqrtPriceX96, maxSqrtPriceX96, liq);
        // This fills in the nodes in the asset.
        WalkerLib.modify(pInfo, lowTick, highTick, data);
        // Settle balances.
        address[] memory tokens = pInfo.tokens();
        int256[] memory balances = new int256[](2);
        balances[0] = data.xBalance;
        balances[1] = data.yBalance;
        RFTLib.settle(msg.sender, tokens, balances, rftData);
        PoolWalker.settle(pInfo, lowTick, highTick, data);
        return assetId;
    }

    /// @inheritdoc IMaker
    function adjustMaker(
        address recipient,
        uint256 assetId,
        uint128 targetLiq,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (address token0, address token1, int256 delta0, int256 delta1) {
        Asset storage asset = AssetLib.getAsset(assetId);
        require(targetLiq >= MIN_MAKER_LIQUIDITY, DeMinimusMaker(targetLiq)); // They should use remove if they want to remove.
        require(asset.owner == msg.sender, NotMakerOwner(asset.owner, msg.sender));
        require(asset.liqType == LiqType.MAKER || asset.liqType == LiqType.MAKER_NC, NotMaker(assetId));
        PoolInfo memory pInfo = PoolLib.getPoolInfo(asset.poolAddr);
        Data memory data = DataImpl.make(pInfo, asset, minSqrtPriceX96, maxSqrtPriceX96, targetLiq);
        WalkerLib.modify(pInfo, asset.lowTick, asset.highTick, data);
        address[] memory tokens = pInfo.tokens();
        int256[] memory balances = new int256[](2);
        if (data.xBalance == 0 && data.yBalance == 0) {
            revert DeMinimusMaker(targetLiq);
        } else if (data.xBalance > 0 || (data.xBalance == 0 && data.yBalance > 0)) {
            // Both should go up together.
            require(data.yBalance >= 0);
            balances[0] = data.xBalance;
            balances[1] = data.yBalance;
            RFTLib.settle(msg.sender, tokens, balances, rftData);
            PoolWalker.settle(pInfo, asset.lowTick, asset.highTick, data);
        } else {
            require(data.yBalance < 0);
            PoolWalker.settle(pInfo, asset.lowTick, asset.highTick, data);
            uint256 removedX = uint256(-data.xBalance);
            uint256 removedY = uint256(-data.yBalance);
            (removedX, removedY) = FeeLib.applyJITPenalties(asset, removedX, removedY);
            balances[0] = -int256(removedX);
            balances[1] = -int256(removedY);
            RFTLib.settle(msg.sender, tokens, balances, rftData);
        }
        // We have to apply jit afterwards in case someone is trying to use adjust to get around that.
        AssetLib.updateTimestamp(asset);
        token0 = tokens[0];
        token1 = tokens[1];
        delta0 = balances[0];
        delta1 = balances[1];
    }

    /// @inheritdoc IMaker
    function removeMaker(
        address recipient,
        uint256 assetId,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (address token0, address token1, uint256 removedX, uint256 removedY) {
        Asset storage asset = AssetLib.getAsset(assetId);
        require(asset.owner == msg.sender, NotMakerOwner(asset.owner, msg.sender));
        require(asset.liqType == LiqType.MAKER || asset.liqType == LiqType.MAKER_NC, NotMaker(assetId));
        PoolInfo memory pInfo = PoolLib.getPoolInfo(asset.poolAddr);
        Data memory data = DataImpl.make(pInfo, asset, minSqrtPriceX96, maxSqrtPriceX96, 0);
        WalkerLib.modify(pInfo, asset.lowTick, asset.highTick, data);
        // Settle balances.
        PoolWalker.settle(pInfo, asset.lowTick, asset.highTick, data);
        removedX = uint256(-data.xBalance); // These are definitely negative.
        removedY = uint256(-data.yBalance);
        (removedX, removedY) = FeeLib.applyJITPenalties(asset, removedX, removedY);
        AssetLib.removeAsset(assetId);
        address[] memory tokens = pInfo.tokens();
        int256[] memory balances = new int256[](2);
        balances[0] = -int256(removedX); // We know they fit since they can only be less (in magnitude) than before.
        balances[1] = -int256(removedY);
        RFTLib.settle(recipient, tokens, balances, rftData);
        // Return values
        token0 = tokens[0];
        token1 = tokens[1];
    }

    // Collecting fees from a position reverts back to the original liquidity profile.
    /// @inheritdoc IMaker
    function collectFees(
        address recipient,
        uint256 assetId,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (uint256 fees0, uint256 fees1) {
        Asset storage asset = AssetLib.getAsset(assetId);
        require(asset.owner == msg.sender, NotMakerOwner(asset.owner, msg.sender));
        require(asset.liqType == LiqType.MAKER || asset.liqType == LiqType.MAKER_NC, NotMaker(assetId));
        PoolInfo memory pInfo = PoolLib.getPoolInfo(asset.poolAddr);
        // We collect simply by targeting the original liq balance.
        Data memory data = DataImpl.make(pInfo, asset, minSqrtPriceX96, maxSqrtPriceX96, asset.liq);
        WalkerLib.modify(pInfo, asset.lowTick, asset.highTick, data);
        PoolWalker.settle(pInfo, asset.lowTick, asset.highTick, data);
        // Update timestamp because for compounding liq, the liq has changed.
        AssetLib.updateTimestamp(asset);
        address[] memory tokens = pInfo.tokens();
        int256[] memory balances = new int256[](2);
        balances[0] = data.xBalance;
        balances[1] = data.yBalance;
        RFTLib.settle(recipient, tokens, balances, rftData);
        fees0 = uint256(-data.xBalance);
        fees1 = uint256(-data.yBalance);
    }

    // TODO: Add function to compound a node. But to get the prefix accurately we have to walk down to that node.
    // Does taker fees need to update first to save on fees cuz mliq is going up?
    // Non-compounding liq is safe.
    // function compound(uint256 key)
}
