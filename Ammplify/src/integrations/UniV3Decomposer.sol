// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// Imports must precede all other declarations to satisfy linters.
// ─────────────────────────────────────────────────────────────────────────────
import { MakerFacet } from "../facets/Maker.sol";
import { RFTPayer } from "../../lib/Commons/src/Util/RFT.sol";
import { IRFTPayer } from "../../lib/Commons/src/Util/RFT.sol";
import { TransferHelper } from "../../lib/Commons/src/Util/TransferHelper.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IUniswapV3Factory } from "v3-core/interfaces/IUniswapV3Factory.sol";
import { INonfungiblePositionManager } from "./univ3-periphery/interfaces/INonfungiblePositionManager.sol";
import { IERC721Receiver } from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import { TickMath } from "v3-core/libraries/TickMath.sol";

// ─────────────────────────────────────────────────────────────────────────────
/// @title UniV3Decomposer
/// @notice  Converts an existing Uniswap-V3 position NFT into an Ammplify Maker
///          position in a single transaction.
contract UniV3Decomposer is RFTPayer, IERC721Receiver {
    // Custom errors ------------------------------------------------------
    error OnlyMakerFacet(address caller);
    error NotPositionOwner(address expected, address sender);
    error PoolNotDeployed();
    error ReentrancyAttempt();

    // Immutable configuration
    INonfungiblePositionManager public immutable NFPM;
    MakerFacet public immutable MAKER;
    address private transient caller;
    uint128 public constant LIQUIDITY_OFFSET = 42;

    event Decomposed(
        uint256 indexed newAssetId,
        uint256 indexed oldTokenId,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    constructor(address _nfpm, address _maker) {
        NFPM = INonfungiblePositionManager(_nfpm);
        MAKER = MakerFacet(_maker);
    }

    /// @notice Calculates the liquidity offset based on tick range
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return liquidityOffset The calculated liquidity offset
    function calculateLiquidityOffset(int24 tickLower, int24 tickUpper) internal pure returns (uint128 liquidityOffset) {
        // Get sqrt prices at the tick boundaries
        uint160 sqrtPriceLower = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtRatioAtTick(tickUpper);

        // Calculate Q96 * 42 / (sqrtPrice(high) - sqrtPrice(low))
        // Q96 is 2^96
        uint256 q96 = 1 << 96;
        uint256 numerator = q96 * LIQUIDITY_OFFSET;
        uint256 denominator = uint256(sqrtPriceUpper) - uint256(sqrtPriceLower);

        // Ensure we don't divide by zero
        if (denominator == 0) {
            return LIQUIDITY_OFFSET; // fallback to the original constant
        }

        liquidityOffset = uint128(numerator / denominator);

        // Ensure minimum offset of 1 to avoid edge cases
        if (liquidityOffset == 0) {
            liquidityOffset = LIQUIDITY_OFFSET;
        }
    }

    /// @notice Prevents reentrancy by locking the contract during the call.
    ///         When locked all nonReentrant functions will revert.
    modifier nonReentrant {
        require(caller == address(0), ReentrancyAttempt());
        caller = msg.sender;
        _;
        caller = msg.sender;
    }

    function decompose(
        uint256 positionId,
        bool isCompounding,
        uint160 minSqrtPriceX96,
        uint160 maxSqrtPriceX96,
        bytes calldata rftData
    ) external nonReentrant returns (uint256 newAssetId) {
        // Verify ownership first via ERC721
        address owner = NFPM.ownerOf(positionId);
        if (owner != msg.sender) revert NotPositionOwner(owner, msg.sender);
        // 1. Read position data we care about
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = NFPM.positions(positionId);

        // 2. Exit position
        NFPM.safeTransferFrom(msg.sender, address(this), positionId);
        if (liquidity > 0) {
            NFPM.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: positionId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        NFPM.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        NFPM.burn(positionId);

        // 3. Recompose in Ammplify
        address factory = NFPM.factory();
        address poolAddr = IUniswapV3Factory(factory).getPool(token0, token1, fee);
        if (poolAddr == address(0)) revert PoolNotDeployed();

        // Calculate dynamic liquidity offset based on tick range
        uint128 liquidityOffset = calculateLiquidityOffset(tickLower, tickUpper);

        newAssetId = MAKER.newMaker(
            msg.sender,
            poolAddr,
            tickLower,
            tickUpper,
            liquidity - liquidityOffset,
            isCompounding,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        emit Decomposed(newAssetId, positionId, token0, token1, fee, tickLower, tickUpper, liquidity);
    }

    /// @inheritdoc IRFTPayer
    function tokenRequestCB(
        address[] calldata tokens,
        int256[] calldata deltas,
        bytes calldata /* data */
    ) external override returns (bytes memory) {
        if (msg.sender != address(MAKER)) revert OnlyMakerFacet(msg.sender);
        for (uint256 i = 0; i < tokens.length; ++i) {
            int256 change = deltas[i];
            address token = tokens[i];
            if (change > 0) {
                TransferHelper.safeTransfer(token, msg.sender, uint256(change));
            }
            // After primary transfer, sweep any dust the contract may still hold for this token
            uint256 residual = IERC20(token).balanceOf(address(this));
            if (residual > 0) {
                TransferHelper.safeTransfer(token, caller, residual);
            }
        }
        return "";
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
