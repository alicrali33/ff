// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Pool } from "./Pool.sol";
import { AssetStore } from "./Asset.sol";
import { VaultStore } from "./vaults/Vault.sol";
import { FeeStore } from "./Fee.sol";

struct Storage {
    AssetStore _assets;
    mapping(address poolAddr => Pool) pools;
    VaultStore _vaults;
    FeeStore _fees;
}

library Store {
    // keccak256(abi.encode(uint256(keccak256("ammplify.storage.20250715")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x56d575db4d6456485aa5ce65d80d7d37cbb42d6dfdcfcad47c900d34e619bc00;

    function load() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_SLOT;
        assembly {
            s.slot := position
        }
    }

    function pool(address poolAddr) internal view returns (Pool storage p) {
        Storage storage s = load();
        p = s.pools[poolAddr];
    }

    function vaults() internal view returns (VaultStore storage v) {
        v = load()._vaults;
    }

    function assets() internal view returns (AssetStore storage a) {
        a = load()._assets;
    }

    function fees() internal view returns (FeeStore storage f) {
        f = load()._fees;
    }
}
