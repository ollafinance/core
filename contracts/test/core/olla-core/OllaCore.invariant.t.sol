// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

contract OllaCoreHandler is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec public asset;
    OllaCore public vault;
    StAztec public stAztec;

    address[] public actors;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(MockAztec _asset, OllaCore _vault, StAztec _stAztec) {
        asset = _asset;
        vault = _vault;
        stAztec = _stAztec;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    /*//////////////////////////////////////////////////////////////
                             CORE ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint96 amount, uint256 actorSeed) external {
        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        asset.mint(actor, assets);
        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
    }
}

contract OllaCoreDepositHandler is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec public asset;
    OllaCore public vault;
    StAztec public stAztec;

    address[] public actors;

    uint256 public previousExchangeRate;
    uint256 public latestExchangeRate;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    /*//////////////////////////////////////////////////////////////
                             CORE ACTIONS
    //////////////////////////////////////////////////////////////*/

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

contract OllaCoreAccountingHandler is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec public asset;
    OllaCore public vault;
    StAztec public stAztec;
    MockAccountingStakingManager public stakingManager;
    MockRewardsVault public rewardsVault;
    address public operator;

    address[] public actors;

    uint256 public lastSlashingDelta;
    uint256 public lastClaimableRewards;
    uint256 public lastTotalStaked;
    uint256 public lastReportTotalAssets;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        MockAztec _asset,
        OllaCore _vault,
        StAztec _stAztec,
        MockAccountingStakingManager _stakingManager,
        MockRewardsVault _rewardsVault,
        address _operator
    ) {
        asset = _asset;
        vault = _vault;
        stAztec = _stAztec;
        stakingManager = _stakingManager;
        rewardsVault = _rewardsVault;
        operator = _operator;
        lastReportTotalAssets = _vault.latestReport().totalAssets;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("actor", i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    /*//////////////////////////////////////////////////////////////
                              CORE ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint96 amount, uint256 actorSeed) external {
        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        asset.mint(actor, assets);
        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor);
        vm.stopPrank();
    }

    function setClaimableRewards(uint96 amount) external {
        uint256 next = uint256(bound(amount, 0, type(uint96).max));
        if (next < lastClaimableRewards) {
            next = lastClaimableRewards;
        }
        lastClaimableRewards = next;
        stakingManager.setClaimableRewards(next);
    }

    function setTotalStaked(uint96 amount) external {
        uint256 next = uint256(bound(amount, 0, type(uint96).max));
        if (next < lastTotalStaked) {
            next = lastTotalStaked;
        }
        lastTotalStaked = next;
        stakingManager.setTotalStaked(next);
    }

    function increaseSlashingDelta(uint96 delta) external {
        uint256 increase = uint256(bound(delta, 0, type(uint96).max));
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        uint256 totalPositive = accounting.bufferedAssets + accounting.stakedPrincipal + accounting.rewardsVaultBalance;
        uint256 next = lastSlashingDelta + increase;
        if (totalPositive == 0) {
            next = 0;
        } else if (stAztec.totalSupply() > 0 && totalPositive > 0) {
            uint256 supply = stAztec.totalSupply();
            uint256 minAssets = (supply + 1e18 - 1) / 1e18;
            uint256 maxAllowed = totalPositive > minAssets ? totalPositive - minAssets : 0;
            if (next > maxAllowed) {
                next = maxAllowed;
            }
        } else if (next > totalPositive) {
            next = totalPositive;
        }
        lastSlashingDelta = next;
        stakingManager.setSlashingDelta(next);
    }

    function mintRewardsVault(uint96 amount) external {
        uint256 assets = uint256(bound(amount, 0, type(uint96).max));
        asset.mint(address(rewardsVault), assets);
    }

    function updateAccounting() external {
        IOllaCore.LatestReport memory report = vault.latestReport();
        lastReportTotalAssets = report.totalAssets;
        vm.prank(operator);
        vault.updateAccounting();
    }
}

contract OllaCoreInvariantTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaCore internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockAccountingStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    MockRewardsVault internal rewardsVault;
    OllaCoreAccountingHandler internal handler;
    address internal operator;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        address governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        withdrawalQueue = new MockWithdrawalQueue();
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(implementation));
        address providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);
        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        operator = makeAddr("operator");
        vm.startPrank(governance);
        vault.grantRole(operatorRole, address(this));
        vault.grantRole(operatorRole, operator);
        vm.stopPrank();

        handler = new OllaCoreAccountingHandler(asset, vault, stAztec, stakingManager, rewardsVault, operator);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_TotalAssetsEqualBuckets() external view {
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        uint256 expectedTotal = accounting.bufferedAssets + accounting.stakedPrincipal + accounting.rewardsVaultBalance
            + accounting.claimableRewards - accounting.slashingDelta;

        assertEq(vault.totalAssets(), expectedTotal, "total assets sum");
    }

    function invariant_ExchangeRateMatchesTotals() external view {
        uint256 supply = stAztec.totalSupply();
        uint256 expectedRate = (vault.totalAssets() + 1).mulDiv(1e18, supply + 1, Math.Rounding.Floor);

        assertEq(vault.exchangeRate(), expectedRate, "exchange rate matches totals");
    }

    /*//////////////////////////////////////////////////////////////
                        REPORTING INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_StoredExchangeRateMatchesSnapshot() external {
        handler.updateAccounting();

        uint256 supply = stAztec.totalSupply();
        IOllaCore.LatestReport memory report = vault.latestReport();
        IOllaCore.FlowCounters memory flows = vault.flowCounters();
        uint256 expectedRate = (report.totalAssets + 1).mulDiv(1e18, supply + 1, Math.Rounding.Floor);

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
        handler.updateAccounting();

        IOllaCore.LatestReport memory report = vault.latestReport();
        uint256 latestTimestamp = report.timestamp;
        assertLe(latestTimestamp, block.timestamp, "report timestamp should not exceed block time");
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER METHODS
    //////////////////////////////////////////////////////////////*/

    function _expectedShares(uint256 assets) internal view returns (uint256) {
        return assets.mulDiv(stAztec.totalSupply() + 1, vault.totalAssets() + 1, Math.Rounding.Floor);
    }

    function _expectedAssets(uint256 shares) internal view returns (uint256) {
        return shares.mulDiv(vault.totalAssets() + 1, stAztec.totalSupply() + 1, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                       CONVERSION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_ConvertToSharesMatchesSpec() external view {
        uint256 assets = bound(uint256(block.timestamp), 1, type(uint96).max);
        assertEq(vault.convertToShares(assets), _expectedShares(assets), "convertToShares matches spec");
    }

    function invariant_GrossRewardsMatchesSignedFlows() external view {
        IOllaCore.LatestReport memory report = vault.latestReport();
        int256 changeInAssets = int256(report.totalAssets) - int256(handler.lastReportTotalAssets());
        int256 expectedGrossSigned = changeInAssets - report.netFlows;
        uint256 expectedGross = expectedGrossSigned > 0 ? uint256(expectedGrossSigned) : 0;

        assertEq(report.grossRewards, expectedGross, "gross rewards matches signed flows");
    }

    function invariant_ConvertToAssetsMatchesSpec() external view {
        uint256 shares = bound(uint256(block.number), 1, type(uint96).max);
        assertEq(vault.convertToAssets(shares), _expectedAssets(shares), "convertToAssets matches spec");
    }

    function invariant_PreviewDepositMatchesSpec() external view {
        uint256 assets = bound(uint256(block.timestamp), 1, type(uint96).max);
        assertEq(vault.previewDeposit(assets), _expectedShares(assets), "previewDeposit matches spec");
    }

    /*//////////////////////////////////////////////////////////////
                       ZERO SUPPLY BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function invariant_ZeroSupplyBehavior() external view {
        uint256 supply = stAztec.totalSupply();
        if (supply != 0) {
            return;
        }

        uint256 total = vault.totalAssets();
        uint256 assets = 1e18;
        uint256 shares = 1e18;

        // With virtual offset: exchangeRate = (total + 1) * 1e18 / (0 + 1)
        uint256 expectedRate = (total + 1).mulDiv(1e18, 1, Math.Rounding.Floor);
        assertEq(vault.exchangeRate(), expectedRate, "zero supply: exchangeRate with virtual offset");

        // convertToShares = assets * (0 + 1) / (total + 1)
        uint256 expectedShares = assets.mulDiv(1, total + 1, Math.Rounding.Floor);
        assertEq(vault.convertToShares(assets), expectedShares, "zero supply: convertToShares with virtual offset");

        // convertToAssets = shares * (total + 1) / (0 + 1)
        uint256 expectedAssets = shares.mulDiv(total + 1, 1, Math.Rounding.Floor);
        assertEq(vault.convertToAssets(shares), expectedAssets, "zero supply: convertToAssets with virtual offset");

        // previewDeposit = assets * (0 + 1) / (total + 1)
        assertEq(vault.previewDeposit(assets), expectedShares, "zero supply: previewDeposit with virtual offset");
    }
}

contract OllaCoreDepositInvariantTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaCore internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    OllaCoreDepositHandler internal handler;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        address governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockStakingManager();
        withdrawalQueue = new MockWithdrawalQueue();
        address rewardsVault = makeAddr("rewardsVault");
        safetyModule = new MockSafetyModule(address(implementation));
        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            IRewardsVault(rewardsVault),
            address(safetyModule)
        );

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.prank(governance);
        vault.grantRole(operatorRole, address(this));

        handler = new OllaCoreDepositHandler(asset, vault, stAztec);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                        EXCHANGE RATE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_ExchangeRateNonDecreasingAfterDeposits() external view {
        assertGe(
            handler.latestExchangeRate(), handler.previousExchangeRate(), "deposit should never decrease exchange rate"
        );
    }
}
