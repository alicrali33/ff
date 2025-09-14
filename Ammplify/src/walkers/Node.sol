// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { LiqNode } from "./Liq.sol";
import { FeeNode } from "./Fee.sol";

struct Node {
    LiqNode liq;
    FeeNode fees;
}
