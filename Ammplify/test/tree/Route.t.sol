// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Route, RouteImpl, Phase } from "../../src/tree/Route.sol";
import { Key, KeyImpl } from "../../src/tree/Key.sol";

struct RouteTestData {
    Key[16] downKeys;
    Key[16] upKeys;
    bool[16] downVisits;
    bool[16] upVisits;
    uint8 downLength;
    uint8 upLength;
}

struct ExpectedKeys {
    Key[16] keys;
    bool[16] visits;
    uint8 length;
}

library ExpectedKeysImpl {
    function add(ExpectedKeys memory self, uint24 base, uint24 width, bool visit) internal pure {
        self.keys[self.length] = KeyImpl.make(base, width);
        self.visits[self.length] = visit;
        self.length++;
    }

    function skip(ExpectedKeys memory self) internal pure {
        self.length++;
    }
}

using ExpectedKeysImpl for ExpectedKeys;

contract RouteTest is Test {
    function testMakeRoute() public pure {
        Route memory r = RouteImpl.make(128, 0, 16);
        assertEq(r.rootWidth, 128);
        assertTrue(r.lca.isEq(KeyImpl.make(0, 32)));
        assertTrue(r.left.isEq(KeyImpl.make(0, 128)));
        assertTrue(r.right.isEq(KeyImpl.make(16, 1)));

        r = RouteImpl.make(128, 2, 13);
        assertTrue(r.lca.isEq(KeyImpl.make(0, 16)));
        assertTrue(r.left.isEq(KeyImpl.make(2, 2)));
        assertTrue(r.right.isEq(KeyImpl.make(12, 2)));

        r = RouteImpl.make(128, 51, 54);
        assertTrue(r.lca.isEq(KeyImpl.make(48, 8)));
        assertTrue(r.left.isEq(KeyImpl.make(51, 1)));
        assertTrue(r.right.isEq(KeyImpl.make(54, 1)));

        r = RouteImpl.make(128, 0, 127);
        assertTrue(r.lca.isEq(KeyImpl.make(0, 128)));
        assertTrue(r.left.isEq(KeyImpl.make(0, 128)));
        assertTrue(r.right.isEq(KeyImpl.make(0, 128)));

        r = RouteImpl.make(128, 64, 127);
        assertTrue(r.lca.isEq(KeyImpl.make(64, 64)));
        assertTrue(r.left.isEq(KeyImpl.make(64, 64)));
        assertTrue(r.right.isEq(KeyImpl.make(0, 128)));

        r = RouteImpl.make(128, 65, 65);
        assertTrue(r.lca.isEq(KeyImpl.make(65, 1)));
        assertTrue(r.left.isEq(KeyImpl.make(65, 1)));
        assertTrue(r.right.isEq(KeyImpl.make(64, 2)));

        r = RouteImpl.make(128, 94, 110);
        assertTrue(r.lca.isEq(KeyImpl.make(64, 64)));
        assertTrue(r.left.isEq(KeyImpl.make(94, 2)));
        assertTrue(r.right.isEq(KeyImpl.make(110, 1)));
    }

    function testRoute0() public {
        // Test the route functionality
        Route memory r = RouteImpl.make(16, 1, 3);
        RouteTestData memory data;
        r.walk(down, up, phase, toRaw(data));
        ExpectedKeys memory eKeys;
        eKeys.add(0, 16, false);
        eKeys.add(0, 8, false);
        eKeys.add(0, 4, false);
        eKeys.skip();
        eKeys.add(2, 2, true);
        eKeys.add(0, 2, false);
        eKeys.add(1, 1, true);
        eKeys.skip();
        assertEqKeys(eKeys, data.downKeys, data.downVisits, data.downLength, "Route 0 Down");

        ExpectedKeys memory eKeys2;
        eKeys2.add(1, 1, true);
        eKeys2.add(0, 2, false);
        eKeys2.add(2, 2, true);
        eKeys2.skip();
        eKeys2.skip();
        eKeys2.add(0, 4, false);
        eKeys2.add(0, 8, false);
        eKeys2.add(0, 16, false);
        assertEqKeys(eKeys2, data.upKeys, data.upVisits, data.upLength, "Route 0 Up");
    }

    function testRoute1() public {
        // Test the route functionality
        Route memory r = RouteImpl.make(64, 45, 57);
        RouteTestData memory data;
        r.walk(down, up, phase, toRaw(data));
        ExpectedKeys memory eKeys;
        eKeys.add(0, 64, false);
        eKeys.add(32, 32, false);
        eKeys.skip();
        eKeys.add(32, 16, false);
        eKeys.add(40, 8, false);
        eKeys.add(44, 4, false);
        eKeys.add(46, 2, true);
        eKeys.add(44, 2, false);
        eKeys.add(45, 1, true);
        eKeys.skip();
        eKeys.add(48, 16, false);
        eKeys.add(48, 8, true);
        eKeys.add(56, 8, false);
        eKeys.add(56, 4, false);
        eKeys.add(56, 2, true);
        assertEqKeys(eKeys, data.downKeys, data.downVisits, data.downLength, "Route 1 Down");

        ExpectedKeys memory eKeys2;
        eKeys2.add(45, 1, true);
        eKeys2.add(44, 2, false);
        eKeys2.add(46, 2, true);
        eKeys2.add(44, 4, false);
        eKeys2.add(40, 8, false);
        eKeys2.add(32, 16, false);
        eKeys2.skip();
        eKeys2.add(56, 2, true);
        eKeys2.add(56, 4, false);
        eKeys2.add(56, 8, false);
        eKeys2.add(48, 8, true);
        eKeys2.add(48, 16, false);
        eKeys2.skip();
        eKeys2.add(32, 32, false);
        eKeys2.add(0, 64, false);
        assertEqKeys(eKeys2, data.upKeys, data.upVisits, data.upLength, "Route 1 Up");
    }

    function testRoute2() public {
        // Test the route functionality
        Route memory r = RouteImpl.make(32, 7, 25);
        RouteTestData memory data;
        r.walk(down, up, phase, toRaw(data));
        ExpectedKeys memory eKeys;
        eKeys.add(0, 32, false);
        eKeys.skip();
        eKeys.add(0, 16, false);
        eKeys.add(8, 8, true);
        eKeys.add(0, 8, false);
        eKeys.add(4, 4, false);
        eKeys.add(6, 2, false);
        eKeys.add(7, 1, true);
        eKeys.skip();
        eKeys.add(16, 16, false);
        eKeys.add(16, 8, true);
        eKeys.add(24, 8, false);
        eKeys.add(24, 4, false);
        eKeys.add(24, 2, true);
        assertEqKeys(eKeys, data.downKeys, data.downVisits, data.downLength, "Route 2 Down");

        ExpectedKeys memory eKeys2;
        eKeys2.add(7, 1, true);
        eKeys2.add(6, 2, false);
        eKeys2.add(4, 4, false);
        eKeys2.add(0, 8, false);
        eKeys2.add(8, 8, true);
        eKeys2.add(0, 16, false);
        eKeys2.skip();
        eKeys2.add(24, 2, true);
        eKeys2.add(24, 4, false);
        eKeys2.add(24, 8, false);
        eKeys2.add(16, 8, true);
        eKeys2.add(16, 16, false);
        eKeys2.skip();
        eKeys2.add(0, 32, false);
        assertEqKeys(eKeys2, data.upKeys, data.upVisits, data.upLength, "Route 2 Up");
    }

    function testRoute3() public {
        // Test the route functionality
        Route memory r = RouteImpl.make(32, 16, 23);
        RouteTestData memory data;
        r.walk(down, up, phase, toRaw(data));
        ExpectedKeys memory eKeys;
        eKeys.add(0, 32, false);
        eKeys.add(16, 16, false);
        eKeys.add(16, 8, true);
        eKeys.skip();
        eKeys.skip();
        assertEqKeys(eKeys, data.downKeys, data.downVisits, data.downLength, "Route 3 Down");

        ExpectedKeys memory eKeys2;
        eKeys2.skip();
        eKeys2.skip();
        eKeys2.add(16, 8, true);
        eKeys2.add(16, 16, false);
        eKeys2.add(0, 32, false);
        assertEqKeys(eKeys2, data.upKeys, data.upVisits, data.upLength, "Route 3 Up");
    }

    function testRoute4() public {
        // Test the route functionality
        Route memory r = RouteImpl.make(32, 16, 24);
        RouteTestData memory data;
        r.walk(down, up, phase, toRaw(data));
        ExpectedKeys memory eKeys;
        eKeys.add(0, 32, false);
        eKeys.add(16, 16, false);
        eKeys.skip();
        eKeys.skip();
        eKeys.add(16, 8, true);
        eKeys.add(24, 8, false);
        eKeys.add(24, 4, false);
        eKeys.add(24, 2, false);
        eKeys.add(24, 1, true);
        assertEqKeys(eKeys, data.downKeys, data.downVisits, data.downLength, "Route 4 Down");

        ExpectedKeys memory eKeys2;
        eKeys2.skip();
        eKeys2.add(24, 1, true);
        eKeys2.add(24, 2, false);
        eKeys2.add(24, 4, false);
        eKeys2.add(24, 8, false);
        eKeys2.add(16, 8, true);
        eKeys2.skip();
        eKeys2.add(16, 16, false);
        eKeys2.add(0, 32, false);
        assertEqKeys(eKeys2, data.upKeys, data.upVisits, data.upLength, "Route 4 Up");
    }

    // Walk Helpers

    function down(Key key, bool visit, bytes memory raw) internal pure {
        RouteTestData memory data = toData(raw);
        data.downKeys[data.downLength] = key;
        data.downVisits[data.downLength] = visit;
        data.downLength++;
    }

    function up(Key key, bool visit, bytes memory raw) internal pure {
        RouteTestData memory data = toData(raw);
        data.upKeys[data.upLength] = key;
        data.upVisits[data.upLength] = visit;
        data.upLength++;
    }

    function phase(Phase walkPhase, bytes memory raw) internal pure {
        // After each phase we add an empty key.
        Key emptyKey = Key.wrap(0);
        if (walkPhase == Phase.ROOT_DOWN || walkPhase == Phase.LEFT_DOWN) {
            down(emptyKey, false, raw);
        } else if (walkPhase == Phase.LEFT_UP || walkPhase == Phase.RIGHT_UP) {
            up(emptyKey, false, raw);
        }
    }

    /* Helpers */

    function toRaw(RouteTestData memory data) internal pure returns (bytes memory raw) {
        assembly {
            raw := data
        }
    }

    function toData(bytes memory raw) internal pure returns (RouteTestData memory data) {
        assembly {
            data := raw
        }
    }

    function assertEqKeys(
        ExpectedKeys memory self,
        Key[16] memory keys,
        bool[16] memory visits,
        uint8 length,
        string memory _msg
    ) internal pure {
        assertEq(length, self.length, _msg);
        for (uint8 i = 0; i < length; i++) {
            console.log("expected key assert index", i);
            assertTrue(keys[i].isEq(self.keys[i]), _msg);
            assertEq(visits[i], self.visits[i], _msg);
        }
    }
}
