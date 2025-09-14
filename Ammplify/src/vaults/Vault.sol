// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { VaultType, VaultPointer } from "./VaultPointer.sol";
import { VaultE4626 } from "./E4626.sol";
import { VaultProxy } from "./VaultProxy.sol";
import { Store } from "../Store.sol";

// Holds overall vault information.
struct VaultStore {
    // Vaults in use.
    mapping(address token => mapping(uint8 => address)) vaults;
    // Vaults we're potentially transfering into.
    mapping(address token => mapping(uint8 => address)) backups;
    // Vault info.
    mapping(address vault => VaultType) vTypes;
    mapping(address vault => VaultE4626) e4626s;
    mapping(address vault => address) usedBy;
    mapping(address vault => uint8) index;
}

/// Each index has a primary vault and a backup vault it may be migrating to.
/// The combination of the two is a VaultProxy.
/// Fetching a VaultProxy and operating on the Vault Storage is done through VaultLib.
/// @dev Previously used and tested in Burve with light changes to the vault storage keys.
library VaultLib {
    // If we have fewer than this many tokens left in a vault, we can remove it.
    uint256 public constant BALANCE_DE_MINIMUS = 10;

    event VaultAdded(address indexed vault, address indexed token, uint8 indexed index, VaultType vType);
    event BackupAdded(address indexed vault, address indexed token, uint8 indexed index, VaultType vType);
    event BackupRemoved(address indexed vault, address indexed token, uint8 indexed index, VaultType vType);
    event VaultTransfer(address indexed fromVault, address indexed toVault);
    event VaultSwapped(address indexed oldVault, address indexed token, uint8 indexed index, address newActiveVault);

    // Thrown when a vault has already been added before.
    error VaultExists(address vault, address token);
    // Thrown when removing a vault that still holds a substantive balance.
    error RemainingVaultBalance(address vault, uint256 balance);
    // This vault type is not currently supported.
    error VaultTypeNotRecognized(VaultType);
    // Thrown during a get if the vault can't be found.
    error VaultNotFound(address);
    // Thrown when there is already a primary and a backup vault.
    error VaultOccupied(address vault, address token, uint8 index);
    // Thrown when removing a vault that is still in use.
    error VaultInUse(address vault, address token, uint8 index);
    // Thrown when deleting or swapping a vault but there is no backup for the vertex.
    error NoBackup(address token, uint8 index);

    /// Add a vault for a token.
    /// Adds as the primary vault if one does not exist yet, then the backup vault.
    function add(address token, uint8 idx, address vault, VaultType vType) internal {
        VaultStore storage vStore = Store.vaults();

        // First add to vault tracking.
        if (vStore.vaults[token][idx] == address(0)) {
            // Add as the primary vault
            vStore.vaults[token][idx] = vault;
            emit VaultAdded(vault, token, idx, vType);
        } else if (vStore.backups[token][idx] == address(0)) {
            // Add as a backup.
            vStore.backups[token][idx] = vault;
            emit BackupAdded(vault, token, idx, vType);
        } else {
            revert VaultOccupied(vault, token, idx);
        }

        // Now add vault details.
        if (vStore.vTypes[vault] != VaultType.UnImplemented) revert VaultExists(vault, token);
        vStore.vTypes[vault] = vType;
        if (vType == VaultType.E4626) vStore.e4626s[vault].init(token, vault);
        else revert VaultTypeNotRecognized(vType);
        vStore.usedBy[vault] = token;
        vStore.index[vault] = idx;
    }

    function remove(address vault) internal {
        VaultPointer memory vPtr = getVault(vault);
        uint256 outstanding = vPtr.totalBalance(false);
        if (outstanding > BALANCE_DE_MINIMUS) revert RemainingVaultBalance(vault, outstanding);

        VaultStore storage vStore = Store.vaults();
        address token = vStore.usedBy[vault];
        uint8 idx = vStore.index[vault];
        if (vStore.vaults[token][idx] == vault) revert VaultInUse(vault, token, idx);

        // We are not the active vault, so we're the backup and we have no tokens. Okay to remove.
        delete vStore.backups[token][idx];

        VaultType vType = vStore.vTypes[vault];
        delete vStore.vTypes[vault];
        // Vault specific operation.
        if (vType == VaultType.E4626) vStore.e4626s[vault].del();
        else revert VaultTypeNotRecognized(vType);
        // Clear bookkeeping.
        delete vStore.usedBy[vault];
        delete vStore.index[vault];

        emit BackupRemoved(vault, token, idx, vType);
    }

    /// Move an amount of tokens from one vault to another.
    /// @dev This implicitly requires that the two vaults are based on the same token
    /// and there can only be two vaults for a given token.
    function transfer(address fromVault, address toVault, uint256 userId, uint256 amount) internal {
        VaultPointer memory from = getVault(fromVault);
        from.withdraw(userId, amount);
        from.commit();
        VaultPointer memory to = getVault(toVault);
        to.deposit(userId, amount);
        to.commit();
        emit VaultTransfer(fromVault, toVault);
    }

    /// Swap the active vault we deposit into.
    function hotSwap(address token, uint8 index) internal returns (address fromVault, address toVault) {
        VaultStore storage vStore = Store.vaults();
        // If there is no backup, then we can't do this.
        if (vStore.backups[token][index] == address(0)) revert NoBackup(token, index);
        // Swap.
        address active = vStore.vaults[token][index];
        address backup = vStore.backups[token][index];
        vStore.vaults[token][index] = backup;
        vStore.backups[token][index] = active;

        // old vault, token, index, new vault
        emit VaultSwapped(active, token, index, backup);
        return (active, backup);
    }

    /* Internal Library */

    /// Deposit an amount of a certain token to be owned by the given assetId
    function deposit(address token, uint8 index, uint256 assetId, uint256 amount) internal {
        VaultProxy memory vProxy = getProxy(token, index);
        vProxy.deposit(assetId, amount);
        vProxy.commit();
    }

    /// Withdraw and return the total balance owned by the given asset.
    function withdraw(address token, uint8 index, uint256 assetId) internal returns (uint256 amount) {
        VaultProxy memory vProxy = getProxy(token, index);
        amount = vProxy.balance(assetId, false);
        vProxy.withdraw(assetId, amount);
        vProxy.commit();
    }

    function balanceOf(
        address token,
        uint8 index,
        uint256 assetId,
        bool roundUp
    ) internal view returns (uint256 amount) {
        VaultProxy memory vProxy = getProxy(token, index);
        amount = vProxy.balance(assetId, roundUp);
    }

    /* Getters */

    /// Get the active and backup addresses for a vault.
    function getVaultAddresses(address token, uint8 index) internal view returns (address active, address backup) {
        VaultStore storage vStore = Store.vaults();
        active = vStore.vaults[token][index];
        backup = vStore.backups[token][index];
    }

    /// Fetch a VaultProxy for the vertex's active vaults.
    function getProxy(address token, uint8 index) internal view returns (VaultProxy memory vProxy) {
        VaultStore storage vStore = Store.vaults();
        vProxy.active = getVault(vStore.vaults[token][index]);
        address backup = vStore.backups[token][index];
        if (backup != address(0)) vProxy.backup = getVault(backup);
    }

    /// Fetch a Vault
    function getVault(address vault) internal view returns (VaultPointer memory vPtr) {
        VaultStore storage vStore = Store.vaults();
        vPtr.vType = vStore.vTypes[vault];
        if (vPtr.vType == VaultType.E4626) {
            VaultE4626 storage v = vStore.e4626s[vault];
            assembly {
                mstore(vPtr, v.slot) // slotAddress is the first field.
            }
            v.fetch(vPtr.temp);
        } else {
            revert VaultNotFound(vault);
        }
    }
}
