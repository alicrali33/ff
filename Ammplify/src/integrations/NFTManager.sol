// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { ERC721 } from "a@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "a@openzeppelin/contracts/access/Ownable.sol";
import { Strings } from "a@openzeppelin/contracts/utils/Strings.sol";
import { Base64 } from "a@openzeppelin/contracts/utils/Base64.sol";
import { RFTLib, RFTPayer } from "Commons/Util/RFT.sol";
import { Auto165Lib } from "Commons/ERC/Auto165.sol";
import { TransferHelper } from "Commons/Util/TransferHelper.sol";
import { IERC20 } from "a@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721Receiver } from "a@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import { Asset, AssetLib } from "../Asset.sol";
import { PoolInfo, PoolLib } from "../Pool.sol";
import { LiqType } from "../walkers/Liq.sol";
import { IView } from "../interfaces/IView.sol";
import { IPool } from "../interfaces/IPool.sol";
import { Store } from "../Store.sol";
import { MakerFacet } from "../facets/Maker.sol";
import { UniV3Decomposer } from "./UniV3Decomposer.sol";
import { INonfungiblePositionManager } from "./univ3-periphery/interfaces/INonfungiblePositionManager.sol";

contract NFTManager is ERC721, Ownable, RFTPayer, IERC721Receiver {
    using Strings for uint256;

    error NotAssetOwner(uint256 assetId, address owner, address sender);
    error AssetNotMinted(uint256 tokenId);
    error OnlyMakerFacet(address caller);
    error NotPositionOwner(uint256 positionId, address owner, address sender);
    error NoActiveTokenRequest();

    // Mapping from asset ID to token ID
    mapping(uint256 => uint256) public assetToToken;
    // Mapping from token ID to asset ID
    mapping(uint256 => uint256) public tokenToAsset;
    // Next token ID to mint
    uint256 private _nextTokenId;
    // Current token request context to pull tokens from caller
    address private _currentTokenRequester;
    // Current supply of tokens (decrements when burned)
    uint256 private _currentSupply;

    // Immutable references to Maker, Decomposer, and NFPM
    MakerFacet public immutable MAKER_FACET;
    UniV3Decomposer public immutable DECOMPOSER;
    INonfungiblePositionManager public immutable NFPM;

    // Events
    event AssetMinted(uint256 indexed assetId, uint256 indexed tokenId, address indexed owner);
    event AssetBurned(uint256 indexed assetId, uint256 indexed tokenId, address indexed owner);
    event PositionDecomposedAndMinted(
        uint256 indexed oldPositionId,
        uint256 indexed newAssetId,
        uint256 indexed tokenId,
        address owner
    );

    constructor(
        address _makerFacet,
        address _decomposer,
        address _nfpm
    ) ERC721("Ammplify Position NFT", "APNFT") Ownable(msg.sender) {
        MAKER_FACET = MakerFacet(_makerFacet);
        DECOMPOSER = UniV3Decomposer(_decomposer);
        NFPM = INonfungiblePositionManager(_nfpm);

        NFPM.setApprovalForAll(address(DECOMPOSER), true);
    }

    /**
     * @notice Creates a new maker position and mints an NFT for it in one transaction
     * @param recipient The address to receive the NFT
     * @param poolAddr The address of the pool
     * @param lowTick The lower tick of the liquidity range
     * @param highTick The upper tick of the liquidity range
     * @param liq The amount of liquidity to provide
     * @param isCompounding Whether the position should compound fees
     * @param minSqrtPriceX96 For any price dependent operations, the actual price of the pool must be above this
     * @param maxSqrtPriceX96 For any price dependent operations, the actual price of the pool must be below this
     * @param rftData Data passed during RFT to the payer
     * @return tokenId The ID of the minted NFT
     * @return assetId The ID of the created asset
     */
    function mintNewMaker(
        address recipient,
        address poolAddr,
        int24 lowTick,
        int24 highTick,
        uint128 liq,
        bool isCompounding,
        uint128 minSqrtPriceX96,
        uint128 maxSqrtPriceX96,
        bytes calldata rftData
    ) external returns (uint256 tokenId, uint256 assetId) {
        // Set the token requester context so tokenRequestCB knows who to pull tokens from
        _currentTokenRequester = msg.sender;

        // Create the maker position
        assetId = MAKER_FACET.newMaker(
            address(this),
            poolAddr,
            lowTick,
            highTick,
            liq,
            isCompounding,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Clear the token requester context
        _currentTokenRequester = address(0);

        // Mint NFT for the new asset
        tokenId = _nextTokenId++;
        assetToToken[assetId] = tokenId;
        tokenToAsset[tokenId] = assetId;
        _currentSupply++;

        _safeMint(recipient, tokenId);

        emit AssetMinted(assetId, tokenId, recipient);
    }

    /**
     * @notice Decomposes an existing Uniswap V3 position and mints an NFT for the resulting Ammplify asset
     * @param positionId The ID of the Uniswap V3 position to decompose
     * @param isCompounding Whether the new position should compound fees
     * @param minSqrtPriceX96 For any price dependent operations, the actual price of the pool must be above this
     * @param maxSqrtPriceX96 For any price dependent operations, the actual price of the pool must be below this
     * @param rftData Data passed during RFT to the payer
     * @return tokenId The ID of the minted NFT
     * @return assetId The ID of the created asset
     */
    function decomposeAndMint(
        uint256 positionId,
        bool isCompounding,
        uint128 minSqrtPriceX96,
        uint128 maxSqrtPriceX96,
        bytes calldata rftData
    ) external returns (uint256 tokenId, uint256 assetId) {
        // Check that the caller owns the Uniswap V3 position
        address positionOwner = NFPM.ownerOf(positionId);
        if (positionOwner != msg.sender) {
            revert NotPositionOwner(positionId, positionOwner, msg.sender);
        }

        // Transfer the position to this contract (using the approval we were given)
        NFPM.safeTransferFrom(positionOwner, address(this), positionId);

        // Approve the nft to the decomposer
        NFPM.approve(address(DECOMPOSER), positionId);

        // Set the token requester context so tokenRequestCB knows who to pull tokens from (if needed)
        _currentTokenRequester = msg.sender;

        // Decompose the Uniswap V3 position
        assetId = DECOMPOSER.decompose(positionId, isCompounding, minSqrtPriceX96, maxSqrtPriceX96, rftData);

        // Clear the token requester context
        _currentTokenRequester = address(0);

        // Mint NFT for the decomposed asset
        tokenId = _nextTokenId++;
        assetToToken[assetId] = tokenId;
        tokenToAsset[tokenId] = assetId;
        _currentSupply++;

        _safeMint(msg.sender, tokenId);

        emit PositionDecomposedAndMinted(positionId, assetId, tokenId, msg.sender);
    }

    /**
     * @notice Burns an NFT and removes the underlying position, collecting fees and returning tokens to the user
     * @param tokenId The ID of the NFT to burn
     * @param minSqrtPriceX96 For any price dependent operations, the actual price of the pool must be above this
     * @param maxSqrtPriceX96 For any price dependent operations, the actual price of the pool must be below this
     * @param rftData Data passed during RFT to the recipient
     * @return token0 The address of token0
     * @return token1 The address of token1
     * @return removedX The amount of token0 removed
     * @return removedY The amount of token1 removed
     * @return fees0 The amount of token0 fees collected
     * @return fees1 The amount of token1 fees collected
     */
    function burnAsset(
        uint256 tokenId,
        uint128 minSqrtPriceX96,
        uint128 maxSqrtPriceX96,
        bytes calldata rftData
    )
        external
        returns (address token0, address token1, uint256 removedX, uint256 removedY, uint256 fees0, uint256 fees1)
    {
        // Check if the token was actually minted by checking if it's been assigned to an asset
        if (tokenId >= _nextTokenId) {
            revert AssetNotMinted(tokenId);
        }

        uint256 assetId = tokenToAsset[tokenId];

        if (ownerOf(tokenId) != msg.sender) {
            revert NotAssetOwner(assetId, ownerOf(tokenId), msg.sender);
        }

        // First collect fees from the position
        (fees0, fees1) = MAKER_FACET.collectFees(msg.sender, assetId, minSqrtPriceX96, maxSqrtPriceX96, rftData);

        // Then remove the maker position
        (token0, token1, removedX, removedY) = MAKER_FACET.removeMaker(
            msg.sender,
            assetId,
            minSqrtPriceX96,
            maxSqrtPriceX96,
            rftData
        );

        // Remove the asset from the NFT mapping
        delete assetToToken[assetId];
        delete tokenToAsset[tokenId];
        _currentSupply--;

        // Burn the NFT
        _burn(tokenId);

        emit AssetBurned(assetId, tokenId, msg.sender);
    }

    /**
     * @notice Collects fees from a position without burning the NFT
     * @param tokenId The ID of the NFT representing the position
     * @param minSqrtPriceX96 For any price dependent operations, the actual price of the pool must be above this
     * @param maxSqrtPriceX96 For any price dependent operations, the actual price of the pool must be below this
     * @param rftData Data passed during RFT to the recipient
     * @return fees0 The amount of token0 fees collected
     * @return fees1 The amount of token1 fees collected
     */
    function collectFees(
        uint256 tokenId,
        uint128 minSqrtPriceX96,
        uint128 maxSqrtPriceX96,
        bytes calldata rftData
    ) external returns (uint256 fees0, uint256 fees1) {
        // Check if the token was actually minted by checking if it's been assigned to an asset
        if (tokenId >= _nextTokenId) {
            revert AssetNotMinted(tokenId);
        }

        uint256 assetId = tokenToAsset[tokenId];

        if (ownerOf(tokenId) != msg.sender) {
            revert NotAssetOwner(assetId, ownerOf(tokenId), msg.sender);
        }

        // Collect fees from the position
        (fees0, fees1) = MAKER_FACET.collectFees(msg.sender, assetId, minSqrtPriceX96, maxSqrtPriceX96, rftData);
    }

    /**
     * @notice Returns the position information associated with a given token ID
     * @param tokenId The ID of the token that represents the position
     * @return assetId The ID of the underlying asset
     * @return owner The address that owns the position
     * @return poolAddr The address of the pool
     * @return token0 The address of token0
     * @return token1 The address of token1
     * @return lowTick The lower end of the tick range
     * @return highTick The higher end of the tick range
     * @return liqType The liquidity type (MAKER, MAKER_NC, TAKER)
     * @return liquidity The liquidity of the position
     * @return timestamp The timestamp of when the asset was last modified
     */
    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint256 assetId,
            address owner,
            address poolAddr,
            address token0,
            address token1,
            int24 lowTick,
            int24 highTick,
            LiqType liqType,
            uint128 liquidity,
            uint128 timestamp
        )
    {
        // Check if the token was actually minted by checking if it's been assigned to an asset
        if (tokenId >= _nextTokenId) {
            revert AssetNotMinted(tokenId);
        }

        assetId = tokenToAsset[tokenId];

        // Get asset info from the View facet instead of directly accessing storage
        // since AssetLib accesses the contract's own storage, not the diamond's storage
        (
            address assetOwner,
            address assetPoolAddr,
            int24 assetLowTick,
            int24 assetHighTick,
            LiqType assetLiqType,
            uint128 assetLiq
        ) = IView(address(MAKER_FACET)).getAssetInfo(assetId);

        if (assetPoolAddr == address(0)) {
            revert("Asset not found or corrupted");
        }

        // Get pool info from the diamond
        PoolInfo memory pInfo = IView(address(MAKER_FACET)).getPoolInfo(assetPoolAddr);

        return (
            assetId,
            assetOwner,
            assetPoolAddr,
            pInfo.token0,
            pInfo.token1,
            assetLowTick,
            assetHighTick,
            assetLiqType,
            assetLiq,
            0 // timestamp - not available from View facet, setting to 0 for now
        );
    }

    /**
     * @notice Returns the asset ID for a given token ID
     * @param tokenId The ID of the token
     * @return The asset ID
     */
    function getAssetId(uint256 tokenId) external view returns (uint256) {
        // Check if the token was actually minted by checking if it's been assigned to an asset
        if (tokenId >= _nextTokenId) {
            revert AssetNotMinted(tokenId);
        }

        return tokenToAsset[tokenId];
    }

    /**
     * @notice Returns the token ID for a given asset ID
     * @param assetId The ID of the asset
     * @return The token ID, or 0 if not minted
     */
    function getTokenId(uint256 assetId) external view returns (uint256) {
        return assetToToken[assetId];
    }

    /**
     * @notice Returns the total supply of minted NFTs
     * @return The total supply
     */
    function totalSupply() public view returns (uint256) {
        return _currentSupply;
    }

    /**
     * @notice Returns the token URI for a given token ID
     * @param tokenId The ID of the token
     * @return The token URI
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(ownerOf(tokenId) != address(0), "Token does not exist");

        // Create metadata JSON
        string memory metadata = _generateMetadata(tokenId);

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(metadata))));
    }

    /**
     * @notice Generates SVG for a token
     * @param tokenId The token ID
     * @return The SVG string
     */
    function _generateSVG(uint256 tokenId) internal view returns (string memory) {
        uint256 assetId = tokenToAsset[tokenId];
        Asset storage asset = AssetLib.getAsset(assetId);

        string memory color = _getColorForLiqType(asset.liqType);

        return
            string(
                abi.encodePacked(
                    '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" viewBox="0 0 400 400">',
                    '<rect width="400" height="400" fill="',
                    color,
                    '"/>',
                    '<circle cx="150" cy="120" r="30" fill="white"/>',
                    '<circle cx="250" cy="120" r="30" fill="white"/>',
                    '<circle cx="150" cy="120" r="15" fill="black"/>',
                    '<circle cx="250" cy="120" r="15" fill="black"/>',
                    '<path d="M 120 200 Q 200 280 280 200" stroke="white" ',
                    'stroke-width="8" fill="none"/>',
                    '<text x="200" y="350" text-anchor="middle" fill="white" ',
                    'font-family="Arial" font-size="16">',
                    "Token #",
                    tokenId.toString(),
                    "</text>",
                    '<text x="200" y="370" text-anchor="middle" fill="white" ',
                    'font-family="Arial" font-size="12">',
                    "Pool: ",
                    _addressToString(asset.poolAddr),
                    "</text>",
                    "</svg>"
                )
            );
    }

    /**
     * @notice Generates metadata JSON for a token
     * @param tokenId The token ID
     * @return The metadata JSON string
     */
    function _generateMetadata(uint256 tokenId) internal view returns (string memory) {
        uint256 assetId = tokenToAsset[tokenId];
        Asset storage asset = AssetLib.getAsset(assetId);
        PoolInfo memory pInfo = PoolLib.getPoolInfo(asset.poolAddr);

        string memory liqTypeString = _getLiqTypeString(asset.liqType);

        return
            string(
                abi.encodePacked(
                    '{"name":"Ammplify Position #',
                    tokenId.toString(),
                    '",',
                    '"description":"Ammplify liquidity position NFT",',
                    '"image":"data:image/svg+xml;base64,',
                    Base64.encode(bytes(_generateSVG(tokenId))),
                    '",',
                    '"attributes":[',
                    '{"trait_type":"Asset ID","value":"',
                    assetId.toString(),
                    '"},',
                    '{"trait_type":"Pool","value":"',
                    _addressToString(asset.poolAddr),
                    '"},',
                    '{"trait_type":"Token 0","value":"',
                    _addressToString(pInfo.token0),
                    '"},',
                    '{"trait_type":"Token 1","value":"',
                    _addressToString(pInfo.token1),
                    '"},',
                    '{"trait_type":"Low Tick","value":"',
                    _int24ToString(asset.lowTick),
                    '"},',
                    '{"trait_type":"High Tick","value":"',
                    _int24ToString(asset.highTick),
                    '"},',
                    '{"trait_type":"Liquidity Type","value":"',
                    liqTypeString,
                    '"},',
                    '{"trait_type":"Liquidity","value":"',
                    _uint128ToString(asset.liq),
                    '"},',
                    '{"trait_type":"Timestamp","value":"',
                    _uint128ToString(asset.timestamp),
                    '"}',
                    "]}"
                )
            );
    }

    /**
     * @notice Gets color for liquidity type
     * @param liqType The liquidity type
     * @return The color string
     */
    function _getColorForLiqType(LiqType liqType) internal pure returns (string memory) {
        if (liqType == LiqType.MAKER) return "#4CAF50"; // Green for compounding maker
        if (liqType == LiqType.MAKER_NC) return "#8BC34A"; // Light green for non-compounding maker
        if (liqType == LiqType.TAKER) return "#FF9800"; // Orange for taker
        return "#9E9E9E"; // Default gray
    }

    /**
     * @notice Gets string representation of liquidity type
     * @param liqType The liquidity type
     * @return The string representation
     */
    function _getLiqTypeString(LiqType liqType) internal pure returns (string memory) {
        if (liqType == LiqType.MAKER) return "Compounding Maker";
        if (liqType == LiqType.MAKER_NC) return "Non-Compounding Maker";
        if (liqType == LiqType.TAKER) return "Taker";
        return "Unknown";
    }

    /**
     * @notice Converts address to string
     * @param addr The address
     * @return The string representation
     */
    function _addressToString(address addr) internal pure returns (string memory) {
        return Strings.toHexString(uint256(uint160(addr)), 20);
    }

    /**
     * @notice Converts int24 to string
     * @param value The int24 value
     * @return The string representation
     */
    function _int24ToString(int24 value) internal pure returns (string memory) {
        if (value < 0) {
            return string(abi.encodePacked("-", uint256(uint24(-value)).toString()));
        } else {
            return uint256(uint24(value)).toString();
        }
    }

    /**
     * @notice Converts uint128 to string
     * @param value The uint128 value
     * @return The string representation
     */
    function _uint128ToString(uint128 value) internal pure returns (string memory) {
        return uint256(value).toString();
    }

    // Required overrides
    function _baseURI() internal pure override returns (string memory) {
        return "";
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId) || Auto165Lib.contains(interfaceId);
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

    /**
     * @notice Implements the RFTPayer interface to handle token requests
     * @param tokens Array of token addresses being requested
     * @param requests Array of token amounts (positive if requested, negative if paid)
     * @return cbData Empty bytes as we don't need to return callback data
     */
    function tokenRequestCB(
        address[] calldata tokens,
        int256[] calldata requests,
        bytes calldata /* data */
    ) external override returns (bytes memory cbData) {
        // Only allow calls from MAKER_FACET
        if (msg.sender != address(MAKER_FACET)) {
            revert OnlyMakerFacet(msg.sender);
        }

        // Must have an active token requester context
        if (_currentTokenRequester == address(0)) {
            revert NoActiveTokenRequest();
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            int256 change = requests[i];
            address token = tokens[i];

            if (change > 0) {
                // Pull tokens from the original caller and send to MAKER_FACET
                TransferHelper.safeTransferFrom(token, _currentTokenRequester, msg.sender, uint256(change));
            } else if (change < 0) {
                // Send tokens from our balance to MAKER_FACET (for fee collection, etc.)
                TransferHelper.safeTransfer(token, msg.sender, uint256(-change));
            }

            // After primary transfer, sweep any dust the contract may still hold for this token
            uint256 residual = IERC20(token).balanceOf(address(this));
            if (residual > 0) {
                TransferHelper.safeTransfer(token, msg.sender, residual);
            }
        }

        return ""; // Return empty callback data
    }
}
