// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { SmoothRateCurveConfig } from "Commons/Math/SmoothRateCurveLib.sol";
import { VaultType } from "../vaults/Vault.sol";

interface IAdmin {
    // Events
    event DefaultFeeCurveSet(SmoothRateCurveConfig feeCurve);
    event FeeCurveSet(address indexed pool, SmoothRateCurveConfig feeCurve);
    event DefaultSplitCurveSet(SmoothRateCurveConfig splitCurve);
    event SplitCurveSet(address indexed pool, SmoothRateCurveConfig splitCurve);
    event DefaultCompoundThresholdSet(uint256 threshold);
    event CompoundThresholdSet(address indexed pool, uint256 threshold);
    event JITPenaltySet(uint64 lifetime, uint64 penaltyX64);

    // Fee related functions
    function setFeeCurve(address pool, SmoothRateCurveConfig calldata feeCurve) external;
    function setDefaultFeeCurve(SmoothRateCurveConfig calldata feeCurve) external;
    function setDefaultSplitCurve(SmoothRateCurveConfig calldata splitCurve) external;
    function setSplitCurve(address pool, SmoothRateCurveConfig calldata splitCurve) external;
    function setDefaultCompoundThreshold(uint128 threshold) external;
    function setCompoundThreshold(address pool, uint128 threshold) external;
    function setJITPenalties(uint64 lifetime, uint64 penaltyX64) external;

    function getFeeConfig(
        address pool
    )
        external
        view
        returns (
            SmoothRateCurveConfig memory feeCurve,
            SmoothRateCurveConfig memory splitCurve,
            uint128 compoundThreshold
        );

    function getDefaultFeeConfig()
        external
        view
        returns (
            SmoothRateCurveConfig memory feeCurve,
            SmoothRateCurveConfig memory splitCurve,
            uint128 compoundThreshold,
            uint64 jitLifetime,
            uint64 jitPenaltyX64
        );

    // Vault related functions
    function viewVaults(address token, uint8 vaultIdx) external view returns (address vault, address backup);
    function addVault(address token, uint8 vaultIdx, address vault, VaultType vType) external;
    function removeVault(address vault) external;
    function swapVault(address token, uint8 vaultId) external returns (address oldVault, address newVault);
    function transferVaultBalance(address fromVault, address toVault, uint256 amount) external;

    // Internal overrides
    function getDelay(bool add) external pure returns (uint32);
}
