// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Key } from "../tree/Key.sol";
import { Route, Phase, RouteImpl } from "../tree/Route.sol";
import { ViewRouteImpl } from "../tree/ViewRoute.sol";
import { FeeWalker } from "./Fee.sol";
import { LiqWalker } from "./Liq.sol";
import { ViewWalker, ViewData } from "./View.sol";
import { Data } from "./Data.sol";
import { PoolInfo } from "../Pool.sol";

library WalkerLib {
    function modify(PoolInfo memory pInfo, int24 lowTick, int24 highTick, Data memory data) internal {
        uint24 low = pInfo.treeTick(lowTick);
        uint24 high = pInfo.treeTick(highTick) - 1;
        Route memory route = RouteImpl.make(pInfo.treeWidth, low, high);
        route.walk(down, up, phase, toRaw(data));
    }

    function down(Key key, bool visit, bytes memory raw) internal {
        Data memory data = toData(raw);
        FeeWalker.down(key, visit, data);
    }

    function up(Key key, bool visit, bytes memory raw) internal {
        Data memory data = toData(raw);
        FeeWalker.up(key, visit, data);
        LiqWalker.up(key, visit, data);
    }

    function phase(Phase walkPhase, bytes memory raw) internal pure {
        Data memory data = toData(raw);
        FeeWalker.phase(walkPhase, data);
        LiqWalker.phase(walkPhase, data);
    }

    /* Helpers */

    function toRaw(Data memory data) internal pure returns (bytes memory raw) {
        assembly {
            raw := data
        }
    }

    function toData(bytes memory raw) internal pure returns (Data memory data) {
        assembly {
            data := raw
        }
    }
}

library ViewWalkerLib {
    function viewAsset(PoolInfo memory pInfo, int24 lowTick, int24 highTick, ViewData memory data) internal view {
        uint24 low = pInfo.treeTick(lowTick);
        uint24 high = pInfo.treeTick(highTick) - 1;
        Route memory route = RouteImpl.make(pInfo.treeWidth, low, high);
        ViewRouteImpl.walkDown(route, down, phase, toRaw(data));
    }

    function down(Key key, bool visit, bytes memory raw) internal view {
        ViewWalker.down(key, visit, toData(raw));
    }

    function phase(Phase walkPhase, bytes memory raw) internal pure {
        ViewWalker.phase(walkPhase, toData(raw));
    }

    /* Helpers */

    function toRaw(ViewData memory data) internal pure returns (bytes memory raw) {
        assembly {
            raw := data
        }
    }

    function toData(bytes memory raw) internal pure returns (ViewData memory data) {
        assembly {
            data := raw
        }
    }
}
