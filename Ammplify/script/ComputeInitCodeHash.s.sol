// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "v3-core/UniswapV3Pool.sol";

contract ComputeInitCodeHashScript is Script {
    function run() external {
        // Compute the init code hash for UniswapV3Pool
        bytes memory poolCreationCode = type(UniswapV3Pool).creationCode;
        bytes32 initCodeHash = keccak256(poolCreationCode);

        console.log("Pool creation code hash:");
        console.logBytes32(initCodeHash);
    }
}
