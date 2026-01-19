// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

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
    uint256 public latestExchangeRate;

    constructor(MockAztec _asset, OllaCore _vault, StAztec _stAztec) {
        asset = _asset;
        vault = _vault;
        stAztec = _stAztec;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }

        latestExchangeRate = vault.exchangeRate();
        previousExchangeRate = latestExchangeRate;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function deposit(uint96 amount, uint256 actorSeed) external {
        previousExchangeRate = latestExchangeRate;

        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        asset.mint(actor, assets);
        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();

        latestExchangeRate = vault.exchangeRate();
    }
}

contract OllaCoreInvariantTest is Test {
    using Math for uint256;

    OllaCore internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockStakingManager internal stakingManager;
    OllaCoreHandler internal handler;
    address internal operator;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        address governance = makeAddr("governance");
        address withdrawalQueue = makeAddr("withdrawalQueue");
        address rewardsVault = makeAddr("rewardsVault");
        address safetyModule = makeAddr("safetyModule");
        vault.initialize(asset, stAztec, stakingManager, governance, withdrawalQueue, rewardsVault, safetyModule);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        operator = makeAddr("operator");
        vm.startPrank(governance);
        vault.grantRole(operatorRole, address(this));
        vault.grantRole(operatorRole, operator);
        vm.stopPrank();

        handler = new OllaCoreHandler(asset, vault, stAztec);
        targetContract(address(handler));
    }

    function invariant_TotalAssetsEqualBuckets() external view {
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        uint256 expectedTotal = accounting.bufferedAssets + accounting.stakedPrincipal + accounting.rewardsVaultBalance
            + accounting.rewardsDelta - accounting.slashingDelta;

        assertEq(vault.totalAssets(), expectedTotal, "total assets sum");
    }

    function invariant_ExchangeRateMatchesTotals() external view {
        uint256 supply = stAztec.totalSupply();
        uint256 expectedRate = supply == 0 ? 1e18 : vault.totalAssets().mulDiv(1e18, supply, Math.Rounding.Floor);

        assertEq(vault.exchangeRate(), expectedRate, "exchange rate matches totals");
    }

    function invariant_StoredExchangeRateMatchesSnapshot() external {
        vm.prank(operator);
        vault.updateAccounting();

        uint256 supply = stAztec.totalSupply();
        IOllaCore.LatestReport memory report = vault.latestReport();
        IOllaCore.FlowCounters memory flows = vault.flowCounters();
        uint256 expectedRate = supply == 0 ? 1e18 : report.totalAssets.mulDiv(1e18, supply, Math.Rounding.Floor);

        assertEq(report.exchangeRate, expectedRate, "stored exchange rate matches snapshot");
        assertEq(report.totalAssets, vault.totalAssets(), "snapshot total assets matches total assets");
        assertEq(
            flows.latestReportCumulativeDeposits,
            flows.cumulativeDeposits,
            "last report deposits equals cumulative deposits"
        );
        assertEq(
            flows.latestReportCumulativeWithdrawals,
            flows.cumulativeWithdrawals,
            "last report withdrawals equals cumulative withdrawals"
        );
    }

    function invariant_LatestReportTimestampMonotonic() external {
        vm.warp(block.timestamp + 1);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory report = vault.latestReport();
        uint256 latestTimestamp = report.timestamp;
        assertLe(latestTimestamp, block.timestamp, "report timestamp should not exceed block time");
    }

    function _expectedShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = stAztec.totalSupply();
        if (supply == 0) {
            return assets;
        }
        return assets.mulDiv(supply, vault.totalAssets(), Math.Rounding.Floor);
    }

    function _expectedAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = stAztec.totalSupply();
        if (supply == 0) {
            return shares;
        }
        return shares.mulDiv(vault.totalAssets(), supply, Math.Rounding.Floor);
    }

    function invariant_ConvertToSharesMatchesSpec() external view {
        uint256 assets = bound(uint256(block.timestamp), 1, type(uint96).max);
        assertEq(vault.convertToShares(assets), _expectedShares(assets), "convertToShares matches spec");
    }

    function invariant_ConvertToAssetsMatchesSpec() external view {
        uint256 shares = bound(uint256(block.number), 1, type(uint96).max);
        assertEq(vault.convertToAssets(shares), _expectedAssets(shares), "convertToAssets matches spec");
    }

    function invariant_PreviewDepositMatchesSpec() external view {
        uint256 assets = bound(uint256(block.timestamp), 1, type(uint96).max);
        assertEq(vault.previewDeposit(assets), _expectedShares(assets), "previewDeposit matches spec");
    }

    function invariant_PreviewRedeemMatchesSpec() external view {
        uint256 shares = bound(uint256(block.number), 1, type(uint96).max);
        assertEq(vault.previewRedeem(shares), _expectedAssets(shares), "previewRedeem matches spec");
    }

    function invariant_ZeroSupplyBehavior() external view {
        uint256 supply = stAztec.totalSupply();
        if (supply != 0) {
            return;
        }

        uint256 assets = 1e18;
        uint256 shares = 1e18;
        assertEq(vault.exchangeRate(), 1e18, "zero supply: exchangeRate should be 1e18");
        assertEq(vault.convertToShares(assets), assets, "zero supply: convertToShares equals assets");
        assertEq(vault.convertToAssets(shares), shares, "zero supply: convertToAssets equals shares");
        assertEq(vault.previewDeposit(assets), assets, "zero supply: previewDeposit equals assets");
        assertEq(vault.previewRedeem(shares), shares, "zero supply: previewRedeem equals shares");
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
        address governance = makeAddr("governance");
        address withdrawalQueue = makeAddr("withdrawalQueue");
        address rewardsVault = makeAddr("rewardsVault");
        address safetyModule = makeAddr("safetyModule");
        vault.initialize(asset, stAztec, stakingManager, governance, withdrawalQueue, rewardsVault, safetyModule);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.prank(governance);
        vault.grantRole(operatorRole, address(this));

        handler = new OllaCoreDepositHandler(asset, vault, stAztec);
        targetContract(address(handler));
    }

    function invariant_ExchangeRateNonDecreasingAfterDeposits() external view {
        assertGe(
            handler.latestExchangeRate(), handler.previousExchangeRate(), "deposit should never decrease exchange rate"
        );
    }
}
