// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "@forge-std/Test.sol";

import { StAztec } from "src/core/StAztec.sol";

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

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    constructor(StAztec _token, StAztecCoreHarness _core) {
        token = _token;
        core = _core;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
    }

    function mint(uint256 amount, uint256 actorSeed) external {
        amount = bound(amount, 1, type(uint96).max);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        core.mint(actor, amount);
    }

    function burn(uint256 amount, uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = token.balanceOf(actor);

        amount = bound(amount, 0, balance);

        if (amount == 0) {
            return;
        }

        core.burn(actor, amount);
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

    function invariant_TotalSupplyEqualsBalances() external view {
        uint256 supply = token.totalSupply();
        uint256 sumBalances;

        uint256 actorsLength = handler.actorsLength();
        for (uint256 i = 0; i < actorsLength; i++) {
            sumBalances += token.balanceOf(handler.actors(i));
        }

        assertEq(supply, sumBalances, "supply equals balances");
    }
}
