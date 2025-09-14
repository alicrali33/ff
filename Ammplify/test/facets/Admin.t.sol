// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { ERC20 } from "a@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SmoothRateCurveConfig } from "Commons/Math/SmoothRateCurveLib.sol";
import { AdminLib } from "Commons/Util/Admin.sol";

import { MultiSetupTest } from "../MultiSetup.u.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { VaultType } from "../../src/vaults/Vault.sol";
import { VaultLib } from "../../src/vaults/Vault.sol";

contract AdminFacetTest is MultiSetupTest {
    uint256 constant TAKER_VAULT_ID = 80085;

    MockERC20 public mockToken;
    MockERC4626 public mockVault;

    address public nonOwner;
    address public testPool;

    SmoothRateCurveConfig public testFeeCurve;
    SmoothRateCurveConfig public testSplitCurve;

    event DefaultFeeCurveSet(SmoothRateCurveConfig feeCurve);
    event FeeCurveSet(address indexed pool, SmoothRateCurveConfig feeCurve);
    event DefaultSplitCurveSet(SmoothRateCurveConfig splitCurve);
    event SplitCurveSet(address indexed pool, SmoothRateCurveConfig splitCurve);
    event DefaultCompoundThresholdSet(uint256 threshold);
    event CompoundThresholdSet(address indexed pool, uint256 threshold);
    event JITPenaltySet(uint64 lifetime, uint64 penaltyX64);
    event VaultAdded(address indexed vault, address indexed token, uint8 indexed index, VaultType vType);

    function setUp() public {
        _newDiamond();
        nonOwner = address(0x1337);
        testPool = address(0xFFF);

        mockToken = new MockERC20("mockToken", "MT", 18);
        mockVault = new MockERC4626(ERC20(address(mockToken)), "mockVault", "MV");

        // // Get test configurations
        testFeeCurve = SmoothRateCurveConfig({
            invAlphaX128: 102084710076281535261119195933814292480,
            betaX64: 14757395258967642112,
            maxUtilX64: 14757395258967642112,
            maxRateX64: 14757395258967642112
        });

        testSplitCurve = SmoothRateCurveConfig({
            invAlphaX128: type(uint128).max,
            betaX64: 14757395258967642112,
            maxUtilX64: 14757395258967642112,
            maxRateX64: 14757395258967642112
        });
    }

    // ============ Fee Configuration Tests ============

    function testSetFeeCurve() public {
        vm.expectEmit(true, false, false, true);
        emit FeeCurveSet(testPool, testFeeCurve);

        adminFacet.setFeeCurve(testPool, testFeeCurve);

        // Verify the configuration was stored
        (SmoothRateCurveConfig memory storedFeeCurve, , ) = adminFacet.getFeeConfig(testPool);
        assertEq(storedFeeCurve.invAlphaX128, testFeeCurve.invAlphaX128);
        assertEq(storedFeeCurve.betaX64, testFeeCurve.betaX64);
        assertEq(storedFeeCurve.maxUtilX64, testFeeCurve.maxUtilX64);
        assertEq(storedFeeCurve.maxRateX64, testFeeCurve.maxRateX64);
    }

    function testSetDefaultFeeCurve() public {
        vm.expectEmit(false, false, false, true);
        emit DefaultFeeCurveSet(testFeeCurve);

        adminFacet.setDefaultFeeCurve(testFeeCurve);

        // Verify the default configuration was stored
        (SmoothRateCurveConfig memory storedFeeCurve, , , , ) = adminFacet.getDefaultFeeConfig();
        assertEq(storedFeeCurve.invAlphaX128, testFeeCurve.invAlphaX128);
        assertEq(storedFeeCurve.betaX64, testFeeCurve.betaX64);
        assertEq(storedFeeCurve.maxUtilX64, testFeeCurve.maxUtilX64);
        assertEq(storedFeeCurve.maxRateX64, testFeeCurve.maxRateX64);
    }

    function testSetSplitCurve() public {
        vm.expectEmit(true, false, false, true);
        emit SplitCurveSet(testPool, testSplitCurve);

        adminFacet.setSplitCurve(testPool, testSplitCurve);

        // Verify the configuration was stored
        (, SmoothRateCurveConfig memory storedSplitCurve, ) = adminFacet.getFeeConfig(testPool);
        assertEq(storedSplitCurve.invAlphaX128, testSplitCurve.invAlphaX128);
        assertEq(storedSplitCurve.betaX64, testSplitCurve.betaX64);
        assertEq(storedSplitCurve.maxUtilX64, testSplitCurve.maxUtilX64);
        assertEq(storedSplitCurve.maxRateX64, testSplitCurve.maxRateX64);
    }

    function testSetDefaultSplitCurve() public {
        vm.expectEmit(false, false, false, true);
        emit DefaultSplitCurveSet(testSplitCurve);

        adminFacet.setDefaultSplitCurve(testSplitCurve);

        // Verify the default configuration was stored
        (, SmoothRateCurveConfig memory storedSplitCurve, , , ) = adminFacet.getDefaultFeeConfig();
        assertEq(storedSplitCurve.invAlphaX128, testSplitCurve.invAlphaX128);
        assertEq(storedSplitCurve.betaX64, testSplitCurve.betaX64);
        assertEq(storedSplitCurve.maxUtilX64, testSplitCurve.maxUtilX64);
        assertEq(storedSplitCurve.maxRateX64, testSplitCurve.maxRateX64);
    }

    function testSetCompoundThreshold() public {
        uint128 threshold = 1e18;
        vm.expectEmit(true, false, false, true);
        emit CompoundThresholdSet(testPool, threshold);

        adminFacet.setCompoundThreshold(testPool, threshold);

        // Verify the configuration was stored
        (, , uint128 storedThreshold) = adminFacet.getFeeConfig(testPool);
        assertEq(storedThreshold, threshold);
    }

    function testSetDefaultCompoundThreshold() public {
        uint128 threshold = 1e18;
        vm.expectEmit(false, false, false, true);
        emit DefaultCompoundThresholdSet(threshold);

        adminFacet.setDefaultCompoundThreshold(threshold);

        // Verify the default configuration was stored
        (, , uint128 storedThreshold, , ) = adminFacet.getDefaultFeeConfig();
        assertEq(storedThreshold, threshold);
    }

    function testSetJITPenalties() public {
        uint64 lifetime = 1 hours;
        uint64 penaltyX64 = 1e18;
        vm.expectEmit(false, false, false, true);
        emit JITPenaltySet(lifetime, penaltyX64);

        adminFacet.setJITPenalties(lifetime, penaltyX64);

        // Verify the configuration was stored
        (, , , uint64 storedLifetime, uint64 storedPenalty) = adminFacet.getDefaultFeeConfig();
        assertEq(storedLifetime, lifetime);
        assertEq(storedPenalty, penaltyX64);
    }

    // // ============ Access Control Tests ============

    function testNonOwnerCannotSetFeeCurve() public {
        vm.prank(nonOwner);
        vm.expectRevert(AdminLib.NotOwner.selector);
        adminFacet.setFeeCurve(testPool, testFeeCurve);
    }

    function testNonOwnerCannotSetVaults() public {
        vm.prank(nonOwner);
        vm.expectRevert(AdminLib.NotOwner.selector);
        adminFacet.addVault(address(mockToken), 0, address(mockVault), VaultType.E4626);
    }

    function testNonOwnerCannotAccessAdminFunctions() public {
        vm.startPrank(nonOwner);

        // These should all revert with NotOwner since non-owner cannot access admin functions
        vm.expectRevert(AdminLib.NotOwner.selector);
        adminFacet.setDefaultFeeCurve(testFeeCurve);

        vm.expectRevert(AdminLib.NotOwner.selector);
        adminFacet.setDefaultSplitCurve(testSplitCurve);

        vm.expectRevert(AdminLib.NotOwner.selector);
        adminFacet.setCompoundThreshold(testPool, 1e18);

        vm.expectRevert(AdminLib.NotOwner.selector);
        adminFacet.setJITPenalties(1 hours, 1e18);

        vm.stopPrank();
    }

    // // ============ Vault Management Tests ============

    function testAddVault() public {
        vm.expectEmit(true, true, true, false);
        emit VaultAdded(address(mockVault), address(mockToken), 0, VaultType.E4626);
        adminFacet.addVault(address(mockToken), 0, address(mockVault), VaultType.E4626);

        // Verify vault was added
        (address vault, address backup) = adminFacet.viewVaults(address(mockToken), 0);
        assertEq(vault, address(mockVault));
        assertEq(backup, address(0));
    }

    function testViewVaults() public {
        // Add a vault first
        adminFacet.addVault(address(mockToken), 0, address(mockVault), VaultType.E4626);

        // View vaults
        (address vault, address backup) = adminFacet.viewVaults(address(mockToken), 0);
        assertEq(vault, address(mockVault));
        assertEq(backup, address(0));
    }

    function testRemoveVault() public {
        // Add a vault first
        adminFacet.addVault(address(mockToken), 0, address(mockVault), VaultType.E4626);

        // Try to remove the vault - should revert with VaultInUse error
        // since the vault is currently active
        vm.expectRevert(
            abi.encodeWithSignature("VaultInUse(address,address,uint8)", address(mockVault), address(mockToken), 0)
        );
        adminFacet.removeVault(address(mockVault));

        // Verify vault is still there
        (address vault, address backup) = adminFacet.viewVaults(address(mockToken), 0);
        assertEq(vault, address(mockVault));
        assertEq(backup, address(0));
    }

    function testSwapVault() public {
        // Add initial vault
        adminFacet.addVault(address(mockToken), 0, address(mockVault), VaultType.E4626);

        // Create a new vault for swapping
        MockERC4626 newVault = new MockERC4626(ERC20(address(mockToken)), "newVault", "NV");

        // Test that swapVault function reverts with NoBackup error
        // since there's no backup vault available for the hot swap
        vm.expectRevert(abi.encodeWithSignature("NoBackup(address,uint8)", address(mockToken), 0));
        adminFacet.swapVault(address(mockToken), 0);

        // Add a backup vault and attempt to swap
        adminFacet.addVault(address(mockToken), 0, address(newVault), VaultType.E4626);
        adminFacet.swapVault(address(mockToken), 0);

        // Verify the vaults have been swapped
        (address vault, address backup) = adminFacet.viewVaults(address(mockToken), 0);
        assertEq(vault, address(newVault));
        assertEq(backup, address(mockVault));

        // Remove the old vault
        adminFacet.removeVault(address(mockVault));
    }

    // function testTransferVaultBalance() public {
    //     // Add source and destination vaults
    //     adminFacet.addVault(address(mockToken), 0, address(mockVault), VaultType.E4626);

    //     MockERC4626 destVault = new MockERC4626(ERC20(address(mockToken)), "destVault", "DV");
    //     adminFacet.addVault(address(mockToken), 0, address(destVault), VaultType.E4626);

    //     // TODO: add position, create taker, transfer taker collateral to new vault

    //     // Test that transferVaultBalance function can be called (will revert due to access control or VaultLib call)
    //     // This tests the basic function signature and access control
    //     // vm.expectRevert(); // Expect revert due to access control or VaultLib call
    //     adminFacet.transferVaultBalance(address(mockVault), address(destVault), transferAmount);
    // }
}
