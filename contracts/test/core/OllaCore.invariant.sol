// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";

contract OllaCoreHandler is Test {
    using Math for uint256;

    MockAztec public asset;
    OllaCore public vault;
    StAztec public stAztec;

    address[] public actors;

    constructor(MockAztec _asset, OllaCore _vault, StAztec _stAztec) {
        asset = _asset;
        vault = _vault;
        stAztec = _stAztec;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint96 amount, uint256 actorSeed) external {
        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        asset.mint(actor, assets);
        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
    }

    function requestRedeem(uint96 shares, uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 supply = stAztec.totalSupply();
        if (supply == 0) {
            return;
        }

        uint256 totalAssets = vault.totalAssets();
        if (totalAssets == 0) {
            return;
        }

        uint256 actorShares = stAztec.balanceOf(actor);
        if (actorShares == 0) {
            return;
        }

        uint256 redeemShares = uint256(bound(shares, 1, actorShares));

        vm.startPrank(actor);
        vault.requestRedeem(redeemShares, actor, actor);
        vm.stopPrank();
    }

    function claimPendingWithdraw(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        IOllaCore.PendingWithdrawal memory pending = vault.pendingWithdrawal(actor);
        if (pending.shares == 0) {
            return;
        }

        vault.claimPendingWithdraw(actor);
    }
}

contract OllaCoreDepositHandler is Test {
    using Math for uint256;

    MockAztec public asset;
    OllaCore public vault;
    StAztec public stAztec;

    address[] public actors;

    uint256 public previousExchangeRate;
    uint256 public lastExchangeRate;

    constructor(MockAztec _asset, OllaCore _vault, StAztec _stAztec) {
        asset = _asset;
        vault = _vault;
        stAztec = _stAztec;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }

        lastExchangeRate = vault.exchangeRate();
        previousExchangeRate = lastExchangeRate;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function deposit(uint96 amount, uint256 actorSeed) external {
        previousExchangeRate = lastExchangeRate;

        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        asset.mint(actor, assets);
        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();

        lastExchangeRate = vault.exchangeRate();
    }
}

contract OllaCoreInvariantTest is Test {
    using Math for uint256;

    OllaCore internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockStakingManager internal stakingManager;
    OllaCoreHandler internal handler;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        vault.initialize(asset, stAztec, stakingManager);

        handler = new OllaCoreHandler(asset, vault, stAztec);
        targetContract(address(handler));
    }

    function invariant_TotalAssetsEqualBuckets() external view {
        uint256 expectedTotal = vault.bufferedAssets() + vault.stakedPrincipal() + vault.rewardsVaultBalance()
            + vault.rewardsDelta() - vault.slashingDelta();

        assertEq(vault.totalAssets(), expectedTotal, "total assets sum");
    }

    function invariant_ExchangeRateMatchesTotals() external view {
        uint256 supply = stAztec.totalSupply();
        uint256 expectedRate = supply == 0 ? 1e18 : vault.totalAssets().mulDiv(1e18, supply, Math.Rounding.Floor);

        assertEq(vault.exchangeRate(), expectedRate, "exchange rate matches totals");
    }

    function invariant_DepositFormulaMatchesSpec() external view {
        uint256 assets = 1e18;
        uint256 supply = stAztec.totalSupply();
        uint256 expectedShares = supply == 0 ? assets : assets.mulDiv(supply, vault.totalAssets(), Math.Rounding.Floor);

        assertEq(vault.depositFormula(assets), expectedShares, "deposit formula matches spec");
    }

    function invariant_ZeroSupplyBehavior() external view {
        uint256 supply = stAztec.totalSupply();
        if (supply != 0) {
            return;
        }

        uint256 assets = 1e18;
        assertEq(vault.exchangeRate(), 1e18, "zero supply exchange rate");
        assertEq(vault.depositFormula(assets), assets, "zero supply deposit formula");
        assertEq(vault.userValue(address(0xBEEF)), 0, "zero supply user value");
    }
}

contract OllaCoreDepositInvariantTest is Test {
    using Math for uint256;

    OllaCore internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockStakingManager internal stakingManager;
    OllaCoreDepositHandler internal handler;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        vault.initialize(asset, stAztec, stakingManager);

        handler = new OllaCoreDepositHandler(asset, vault, stAztec);
        targetContract(address(handler));
    }

    function invariant_ExchangeRateMonotonicWithDeposits() external view {
        assertGe(handler.lastExchangeRate(), handler.previousExchangeRate(), "exchange rate monotonic");
    }

    function invariant_UserValueMatchesFormula() external view {
        uint256 rate = vault.exchangeRate();
        uint256 actorCount = handler.actorsLength();

        for (uint256 i = 0; i < actorCount; i++) {
            address actor = handler.actorAt(i);
            uint256 shares = stAztec.balanceOf(actor);
            uint256 expectedValue = shares == 0 ? 0 : shares.mulDiv(rate, 1e18, Math.Rounding.Floor);

            assertEq(vault.userValue(actor), expectedValue, "user value matches formula");
        }
    }
}
