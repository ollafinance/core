// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";

import {StAztec} from "src/core/StAztec.sol";

contract StAztecCoreHarness {
    StAztec public token;

    function setToken(StAztec _token) external {
        token = _token;
    }

    function mint(address to, uint256 amount) external {
        token.mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        token.burn(from, amount);
    }
}

contract StAztecHandler is Test {
    StAztec public token;
    StAztecCoreHarness public core;

    address[] public actors;
    uint256 public ghostTotalSupply;

    constructor(StAztec _token, StAztecCoreHarness _core) {
        token = _token;
        core = _core;

        actors.push(makeAddr("actor-0"));
        actors.push(makeAddr("actor-1"));
        actors.push(makeAddr("actor-2"));
        actors.push(makeAddr("actor-3"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function mint(uint96 amount, uint256 actorSeed) external {
        amount = uint96(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        core.mint(actor, amount);
        ghostTotalSupply += amount;
    }

    function burn(uint96 amount, uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = token.balanceOf(actor);

        if (balance == 0) {
            return;
        }

        uint256 burnAmount = bound(amount, 1, balance);
        core.burn(actor, burnAmount);
        ghostTotalSupply -= burnAmount;
    }

    function transfer(uint96 amount, uint256 fromSeed, uint256 toSeed) external {
        address from = actors[bound(fromSeed, 0, actors.length - 1)];
        address to = actors[bound(toSeed, 0, actors.length - 1)];
        uint256 balance = token.balanceOf(from);

        if (balance == 0) {
            return;
        }

        uint256 sendAmount = bound(amount, 1, balance);
        vm.prank(from);
        token.transfer(to, sendAmount);
    }
}

contract StAztecInvariantTest is Test {
    StAztec internal token;
    StAztecCoreHarness internal core;
    StAztecHandler internal handler;

    function setUp() external {
        core = new StAztecCoreHarness();
        token = new StAztec(address(core));
        core.setToken(token);

        handler = new StAztecHandler(token, core);
        targetContract(address(handler));
    }

    function invariant_TotalSupplyEqualsTrackedBalances() external view {
        uint256 supply = token.totalSupply();
        uint256 sumBalances;
        uint256 count = handler.actorCount();

        for (uint256 i = 0; i < count; i++) {
            sumBalances += token.balanceOf(handler.actors(i));
        }

        assertEq(supply, sumBalances, "supply equals tracked balances");
    }

    function invariant_TotalSupplyMatchesGhost() external view {
        assertEq(token.totalSupply(), handler.ghostTotalSupply(), "supply matches ghost");
    }
}
