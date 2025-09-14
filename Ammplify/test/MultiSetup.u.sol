// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { IERC4626 } from "a@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20 } from "a@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Strings } from "a@openzeppelin/contracts/utils/Strings.sol";
import { IDiamond } from "Commons/Diamond/interfaces/IDiamond.sol";
import { DiamondCutFacet } from "Commons/Diamond/facets/DiamondCutFacet.sol";
import { VaultType } from "../src/vaults/Vault.sol";

import { SimplexDiamond } from "../src/Diamond.sol";
import { AdminFacet } from "../src/facets/Admin.sol";
import { MakerFacet } from "../src/facets/Maker.sol";
import { TakerFacet } from "../src/facets/Taker.sol";
import { PoolFacet } from "../src/facets/Pool.sol";
import { ViewFacet } from "../src/facets/View.sol";
import { PoolInfo } from "../src/Pool.sol";

import { UniV3IntegrationSetup } from "./UniV3.u.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockERC4626 } from "./mocks/MockERC4626.sol";
import { NonfungiblePositionManager } from "./mocks/nfpm/NonfungiblePositionManager.sol";

contract MultiSetupTest is Test, UniV3IntegrationSetup {
    // Note: removed the constant tag so we can override INITAL_VALUE in interiting tests
    uint256 public INITIAL_MINT_AMOUNT = 1e30;
    uint128 public INITIAL_VALUE = 1_000_000e18;
    NonfungiblePositionManager public nfpm;

    /* Diamond */
    address public diamond;
    AdminFacet public adminFacet;
    MakerFacet public makerFacet;
    TakerFacet public takerFacet;
    PoolFacet public poolFacet;
    ViewFacet public viewFacet;

    /* Test Tokens */
    /// Two mock erc20s for convenience. These are guaranteed to be sorted.
    MockERC20 public token0;
    MockERC20 public token1;
    address[] public tokens;
    IERC4626[] public vaults;

    /* Some Test accounts */
    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /// Deploy the diamond and facets
    function _newDiamond() internal {
        diamond = address(new SimplexDiamond());

        adminFacet = AdminFacet(diamond);
        makerFacet = MakerFacet(diamond);
        takerFacet = TakerFacet(diamond);
        poolFacet = PoolFacet(diamond);
        viewFacet = ViewFacet(diamond);
    }

    function _deployNFPM() internal {
        nfpm = new NonfungiblePositionManager(address(factory), address(0), address(0));
    }

    /// Call this last since it messes with prank.
    function _fundAccount(address account) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(account, INITIAL_MINT_AMOUNT);
        }

        // Approve diamond for all test accounts
        vm.startPrank(account);
        for (uint256 i = 0; i < tokens.length; ++i) {
            MockERC20(tokens[i]).approve(address(diamond), type(uint256).max);
        }
        vm.stopPrank();
    }

    /// Create vaults for token0 and token1 from a pool using the admin facet
    /// @param poolAddr The address of the pool to get tokens from
    function _createPoolVaults(address poolAddr) internal {
        // Get pool information to find token0 and token1
        PoolInfo memory pInfo = viewFacet.getPoolInfo(poolAddr);

        // Create MockERC4626 vaults for both tokens
        MockERC4626 vault0 = new MockERC4626(ERC20(pInfo.token0), "Vault0", "V0");
        MockERC4626 vault1 = new MockERC4626(ERC20(pInfo.token1), "Vault1", "V1");

        // Add vaults to the admin facet (index 0 for token0, index 1 for token1)
        adminFacet.addVault(pInfo.token0, 0, address(vault0), VaultType.E4626);
        adminFacet.addVault(pInfo.token1, 1, address(vault1), VaultType.E4626);

        // Add vaults to the vaults array for tracking
        vaults.push(vault0);
        vaults.push(vault1);
    }
}
