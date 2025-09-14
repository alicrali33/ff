// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test, console } from "forge-std/Test.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockERC4626 } from "../mocks/MockERC4626.sol";
import { IERC4626 } from "forge-std/interfaces/IERC4626.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { ERC20 } from "a@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { VaultTemp } from "../../src/vaults/VaultPointer.sol";
import { VaultE4626, VaultE4626Impl } from "../../src/vaults/E4626.sol";

contract E4626Test is Test {
    IERC20 public token;
    IERC4626 public e4626;
    VaultE4626 public vault;
    uint256[] public ids;

    function setUp() public {
        token = IERC20(address(new MockERC20("test", "TEST", 18)));
        MockERC20(address(token)).mint(address(this), 1 << 128);
        e4626 = IERC4626(address(new MockERC4626(ERC20(address(token)), "vault", "V")));
        token.approve(address(e4626), 1 << 128);
        vault.init(address(token), address(e4626));
    }

    // Test an empty fetch and commit
    function testEmpty() public {
        uint256 id = 1;
        VaultTemp memory temp;
        vault.fetch(temp);
        assertEq(vault.balance(temp, id, false), 0);
        // Empty commit.
        vault.commit(temp);
    }

    function testDeposit() public {
        uint256 id = 1;
        VaultTemp memory temp;
        vault.fetch(temp);
        vault.deposit(temp, id, 1e10);
        vault.commit(temp);
        assertEq(vault.balance(temp, id, false), 1e10);
        assertEq(token.balanceOf(address(this)), (1 << 128) - 1e10);
        assertGt(vault.totalVaultShares, 0);
        uint256 shares = vault.shares[id];
        assertGt(shares, 0);
        assertEq(vault.totalShares, shares);
    }

    function testWithdraw() public {
        uint256 id = 1;
        {
            VaultTemp memory temp;
            vault.fetch(temp);
            vault.deposit(temp, id, 1e10);
            vault.commit(temp);
            assertEq(vault.balance(temp, id, false), 1e10);
        }
        assertEq(token.balanceOf(address(this)), (1 << 128) - 1e10);
        // Now withdraw
        {
            VaultTemp memory temp;
            vault.fetch(temp);
            vault.withdraw(temp, id, 1e10);
            vault.commit(temp);
            assertEq(vault.balance(temp, id, false), 0);
        }
        assertEq(token.balanceOf(address(this)), 1 << 128);
        assertEq(vault.shares[id], 0);
        assertEq(vault.totalShares, 0);
        assertEq(vault.totalVaultShares, 0);
    }

    function testMultipleDeposits() public {
        uint256 id1 = 1;
        uint256 id2 = 2;
        ids.push(id1);
        ids.push(id2);
        {
            VaultTemp memory temp;
            vault.fetch(temp);
            vault.deposit(temp, id1, 1e10);
            assertEq(vault.balance(temp, id1, false), 1e10);
            assertEq(vault.balance(temp, id2, false), 0);
            assertEq(vault.totalBalance(temp, ids, false), 1e10);
            vault.deposit(temp, id2, 2e10);
            assertEq(vault.balance(temp, id1, false), 1e10);
            assertEq(vault.balance(temp, id2, false), 2e10);
            assertEq(vault.totalBalance(temp, ids, false), 3e10);
            vault.deposit(temp, id1, 5e10);
            assertEq(vault.balance(temp, id1, false), 6e10);
            assertEq(vault.balance(temp, id2, false), 2e10);
            assertEq(vault.totalBalance(temp, ids, false), 8e10);
            vault.commit(temp);
        }
        // Check again after committed.
        {
            VaultTemp memory temp;
            vault.fetch(temp);
            assertEq(vault.balance(temp, id1, false), 6e10);
            assertEq(vault.balance(temp, id2, false), 2e10);
            assertEq(vault.totalBalance(temp, ids, false), 8e10);
            vault.commit(temp);
        }
        // Now let's withdraw from one of them.
        {
            VaultTemp memory temp;
            vault.fetch(temp);
            vault.withdraw(temp, id1, 15e9);
            vault.withdraw(temp, id1, 5e9);
            assertEq(vault.balance(temp, id1, false), 4e10);
            assertEq(vault.balance(temp, id2, false), 2e10);
            assertEq(vault.totalBalance(temp, ids, false), 6e10);
            vault.commit(temp);
        }
        // And let's deposit into the ids one more time.
        {
            VaultTemp memory temp;
            vault.fetch(temp);
            vault.deposit(temp, id1, 3e10);
            vault.deposit(temp, id2, 10e10);
            assertEq(vault.balance(temp, id1, true), 7e10);
            assertEq(vault.balance(temp, id2, true), 12e10);
            assertEq(vault.totalBalance(temp, ids, true), 19e10);
            vault.commit(temp);
        }
    }
}
