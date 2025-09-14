// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Script } from "forge-std/Script.sol";

/// @dev See the Solidity Scripting tutorial: https://book.getfoundry.sh/tutorials/solidity-scripting
contract FooScript is Script {
    function run() public {
        vm.startBroadcast();
        //    foo = new Foo();
        vm.stopBroadcast();
    }
}
