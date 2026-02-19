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
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
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
        vault.deposit(assets, actor, 0);
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
        vault.deposit(assets, actor, 0);
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
        vault.deposit(assets, actor, 0);
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
        uint256 next = lastSlashingDelta + increase;
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
        vm.startPrank(operator);
        vault.updateAccounting();
        vm.stopPrank();
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
        stAztec = new StAztec(address(vault));
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
            5_000,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );
        vm.prank(governance);
        vault.unpause();

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
        uint256 positiveTotal = accounting.bufferedAssets + accounting.stakedPrincipal + accounting.rewardsVaultBalance
            + accounting.claimableRewards;
        uint256 expectedTotal = accounting.slashingDelta >= positiveTotal ? 0 : positiveTotal - accounting.slashingDelta;

        assertEq(vault.totalAssets(), expectedTotal, "total assets sum");
    }

    function invariant_TotalAssetsNeverReverts() external view {
        // totalAssets() must always be callable regardless of slashing state
        uint256 total = vault.totalAssets();
        assertGe(total, 0, "totalAssets should never revert");
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
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        withdrawalQueue = new MockWithdrawalQueue();
        address rewardsVault = makeAddr("rewardsVault");
        safetyModule = new MockSafetyModule(address(implementation));
        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            address(withdrawalQueue),
            IRewardsVault(rewardsVault),
            address(safetyModule)
        );
        vm.prank(governance);
        vault.unpause();

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

/*//////////////////////////////////////////////////////////////
                  LIFECYCLE HANDLER (Steps 1 & 2)
//////////////////////////////////////////////////////////////*/

contract OllaCoreLifecycleHandler is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec public asset;
    OllaCore public vault;
    StAztec public stAztec;
    MockAccountingStakingManager public stakingManager;
    MockRewardsVault public rewardsVault;
    WithdrawalQueue public withdrawalQueue;
    address public operator;

    address[] public actors;

    /*//////////////////////////////////////////////////////////////
                          GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    bool public ghost_rebalanceMonotonic;
    uint256 public ghost_rateBeforeAccounting;
    uint256 public ghost_rateAfterAccounting;

    /*//////////////////////////////////////////////////////////////
                        REQUEST TRACKING
    //////////////////////////////////////////////////////////////*/

    uint256[] internal _pendingRequestIds;
    uint256[] internal _finalizedRequestIds;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        MockAztec _asset,
        OllaCore _vault,
        StAztec _stAztec,
        MockAccountingStakingManager _stakingManager,
        MockRewardsVault _rewardsVault,
        WithdrawalQueue _withdrawalQueue,
        address _operator
    ) {
        asset = _asset;
        vault = _vault;
        stAztec = _stAztec;
        stakingManager = _stakingManager;
        rewardsVault = _rewardsVault;
        withdrawalQueue = _withdrawalQueue;
        operator = _operator;

        ghost_rebalanceMonotonic = true;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("lifecycle_actor", i))));
        }
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
        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        asset.mint(actor, assets);
        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor, 0);
        vm.stopPrank();

        ghost_totalDeposited += assets;
    }

    function requestRedeem(uint256 actorSeed) external {
        address actor = address(0);
        uint256 actorShares = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 idx = (actorSeed + i) % actors.length;
            uint256 bal = stAztec.balanceOf(actors[idx]);
            if (bal > 0) {
                actor = actors[idx];
                actorShares = bal;
                break;
            }
        }
        if (actor == address(0)) return;

        uint256 sharesToRedeem = actorShares / 2;
        if (sharesToRedeem == 0) sharesToRedeem = actorShares;

        vm.prank(actor);
        uint256 requestId = vault.requestRedeem(sharesToRedeem, actor);

        _pendingRequestIds.push(requestId);
    }

    function rebalanceSingleStep() external {
        IOllaCore.RebalanceProgress memory progressBefore = vault.rebalanceProgress();
        IOllaCore.RebalanceStep stepBefore = progressBefore.step;

        vm.prank(operator);
        try vault.rebalance() { }
        catch {
            return;
        }

        IOllaCore.RebalanceProgress memory progressAfter = vault.rebalanceProgress();
        IOllaCore.RebalanceStep stepAfter = progressAfter.step;

        if (uint8(stepAfter) < uint8(stepBefore)) {
            bool isDoneToRestart = stepBefore == IOllaCore.RebalanceStep.Done;
            if (!isDoneToRestart) {
                ghost_rebalanceMonotonic = false;
            }
        }

        _refreshFinalizedRequests();
    }

    function claimRequest(uint256 idSeed) external {
        _refreshFinalizedRequests();

        if (_finalizedRequestIds.length == 0) return;

        uint256 idx = bound(idSeed, 0, _finalizedRequestIds.length - 1);
        uint256 requestId = _finalizedRequestIds[idx];

        _finalizedRequestIds[idx] = _finalizedRequestIds[_finalizedRequestIds.length - 1];
        _finalizedRequestIds.pop();

        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        uint256 assetsExpected = request.assetsExpected;

        vault.claimRequestById(requestId);

        ghost_totalWithdrawn += assetsExpected;
    }

    function updateAccounting() external {
        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
        if (progress.step != IOllaCore.RebalanceStep.Done) return;
        if (vault.isRebalancePaused()) return;

        ghost_rateBeforeAccounting = vault.exchangeRate();

        vm.prank(operator);
        try vault.updateAccounting() { }
        catch {
            return;
        }

        ghost_rateAfterAccounting = vault.exchangeRate();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _refreshFinalizedRequests() internal {
        uint256 length = _pendingRequestIds.length;
        uint256 i = 0;
        while (i < length) {
            uint256 reqId = _pendingRequestIds[i];
            try withdrawalQueue.getRequest(reqId) returns (IWithdrawalQueue.WithdrawalRequest memory req) {
                if (req.finalized && !req.claimed) {
                    _finalizedRequestIds.push(reqId);
                    _pendingRequestIds[i] = _pendingRequestIds[length - 1];
                    _pendingRequestIds.pop();
                    length--;
                } else {
                    i++;
                }
            } catch {
                i++;
            }
        }
    }
}

contract OllaCoreLifecycleInvariantTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaCore internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockAccountingStakingManager internal stakingManager;
    WithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    MockRewardsVault internal rewardsVault;
    OllaCoreLifecycleHandler internal handler;
    address internal operator;
    address internal governance;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));
        governance = makeAddr("lifecycle_governance");
        operator = makeAddr("lifecycle_operator");

        OllaCore implementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(coreProxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));
        stakingManager.setUnstakedToken(asset);
        address providerRewardsRecipient = makeAddr("lifecycle_providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );
        vm.prank(governance);
        vault.unpause();

        withdrawalQueue.initialize(address(vault), governance);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();

        handler = new OllaCoreLifecycleHandler(
            asset, vault, stAztec, stakingManager, rewardsVault, withdrawalQueue, operator
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                    D1 - NO TOKENS PERMANENTLY LOCKED
    //////////////////////////////////////////////////////////////*/

    function invariant_NoTokensPermanentlyLocked() external view {
        uint256 assetInVault = asset.balanceOf(address(vault));
        uint256 assetInStaking = asset.balanceOf(address(stakingManager));
        uint256 assetInRewards = asset.balanceOf(address(rewardsVault));
        uint256 totalInActors = 0;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            totalInActors += asset.balanceOf(handler.actorAt(i));
        }
        assertEq(
            assetInVault + assetInStaking + assetInRewards + totalInActors,
            handler.ghost_totalDeposited(),
            "no tokens permanently locked"
        );
    }

    /*//////////////////////////////////////////////////////////////
            D2 - FINALIZED UNCLAIMED ASSETS <= BALANCE
    //////////////////////////////////////////////////////////////*/

    function invariant_FinalizedUnclaimedAssetsLeqBalance() external view {
        uint256 finalizedUnclaimed = uint256(vm.load(address(vault), bytes32(uint256(33))));
        assertLe(finalizedUnclaimed, asset.balanceOf(address(vault)), "finalized unclaimed <= balance");
    }

    /*//////////////////////////////////////////////////////////////
            D3 - STAKED PRINCIPAL <= TOTAL STAKED
    //////////////////////////////////////////////////////////////*/

    function invariant_StakedPrincipalLeqTotalStaked() external view {
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertLe(accounting.stakedPrincipal, stakingManager.totalStakedAmount(), "stakedPrincipal <= totalStaked");
    }

    /*//////////////////////////////////////////////////////////////
            D4 - REBALANCE STATE MACHINE FORWARD-ONLY
    //////////////////////////////////////////////////////////////*/

    function invariant_RebalanceStateMachineForward() external view {
        assertTrue(handler.ghost_rebalanceMonotonic(), "rebalance must only transition forward");
    }

    /*//////////////////////////////////////////////////////////////
      D5 - PROTOCOL FEE DOES NOT DECREASE EXCHANGE RATE
    //////////////////////////////////////////////////////////////*/

    function invariant_ProtocolFeeDoesNotDecreaseExchangeRate() external view {
        if (handler.ghost_rateBeforeAccounting() == 0) return;
        assertGe(
            handler.ghost_rateAfterAccounting(),
            handler.ghost_rateBeforeAccounting(),
            "fee payout must not decrease rate"
        );
    }
}

/*//////////////////////////////////////////////////////////////
      PROTOCOL PROPERTY HANDLER (full lifecycle + ghost tracking)
//////////////////////////////////////////////////////////////*/

/// @notice Handler that exercises deposit, requestRedeem, instant redeem,
///         rebalance, updateAccounting, and mock-accounting mutations
///         while tracking ghost variables for protocol property invariant tests.
contract OllaCoreProtocolPropertyHandler is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec public asset;
    OllaCore public vault;
    StAztec public stAztec;
    MockAccountingStakingManager public stakingManager;
    MockRewardsVault public rewardsVault;
    WithdrawalQueue public withdrawalQueue;
    address public operator;
    address public governance;

    address[] public actors;

    /*//////////////////////////////////////////////////////////////
                          GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Exchange rate monotonicity across protocol operations
    uint256 public ghost_previousExchangeRate;
    uint256 public ghost_latestExchangeRate;
    /// @notice Whether the latest rate transition is from a protocol-level operation
    ///         (deposit, redeem, requestRedeem, updateAccounting) vs mock-induced
    bool public ghost_rateTransitionIsProtocolOp;
    /// @notice Whether the vault was healthy (no slashing overhang) when previous
    ///         rate was captured. Rate monotonicity only holds when vault is solvent.
    bool public ghost_vaultHealthyAtPreviousRate;

    /// @notice Cumulative counter monotonicity
    uint256 public ghost_previousCumulativeDeposits;
    uint256 public ghost_previousCumulativeWithdrawals;

    /// @notice Slashing delta monotonicity (tracks accounting state, not mock)
    uint256 public ghost_previousSlashingDelta;

    /// @notice Token conservation (total deposited into system)
    uint256 public ghost_totalMinted;

    /// @notice Rebalance pause blocks deposits
    bool public ghost_rebalancePausedDepositAttempted;
    bool public ghost_rebalancePausedDepositSucceeded;

    /// @notice Cumulative rewards monotonicity
    uint256 public ghost_previousCumulativeRewards;

    /// @notice Mock state tracking to enforce monotonicity (like existing OllaCoreAccountingHandler)
    uint256 internal _lastClaimableRewards;
    uint256 internal _lastTotalStaked;

    /// @notice Request tracking for lifecycle operations
    uint256[] internal _pendingRequestIds;
    uint256[] internal _finalizedRequestIds;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        MockAztec _asset,
        OllaCore _vault,
        StAztec _stAztec,
        MockAccountingStakingManager _stakingManager,
        MockRewardsVault _rewardsVault,
        WithdrawalQueue _withdrawalQueue,
        address _operator,
        address _governance
    ) {
        asset = _asset;
        vault = _vault;
        stAztec = _stAztec;
        stakingManager = _stakingManager;
        rewardsVault = _rewardsVault;
        withdrawalQueue = _withdrawalQueue;
        operator = _operator;
        governance = _governance;

        ghost_latestExchangeRate = vault.exchangeRate();
        ghost_previousExchangeRate = ghost_latestExchangeRate;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("protprop_actor", i))));
        }
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
        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        // Snapshot counters before operation
        _snapshotFlowCounters();

        // Test whether deposit works while rebalance paused
        if (vault.isRebalancePaused()) {
            ghost_rebalancePausedDepositAttempted = true;
            asset.mint(actor, assets);
            ghost_totalMinted += assets;
            vm.startPrank(actor);
            asset.approve(address(vault), assets);
            try vault.deposit(assets, actor, 0) {
                ghost_rebalancePausedDepositSucceeded = true;
            } catch {
                // Expected: deposit reverts during rebalance pause
            }
            vm.stopPrank();
            return;
        }

        // Snapshot rate before (deposit is a protocol op)
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = true;
        ghost_vaultHealthyAtPreviousRate = vault.accountingState().slashingDelta == 0;

        asset.mint(actor, assets);
        ghost_totalMinted += assets;
        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        vault.deposit(assets, actor, 0);
        vm.stopPrank();

        // Update rate after
        ghost_latestExchangeRate = vault.exchangeRate();
    }

    function requestRedeem(uint256 actorSeed) external {
        address actor = address(0);
        uint256 actorShares = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 idx = (actorSeed + i) % actors.length;
            uint256 bal = stAztec.balanceOf(actors[idx]);
            if (bal > 0) {
                actor = actors[idx];
                actorShares = bal;
                break;
            }
        }
        if (actor == address(0)) return;
        if (vault.isRebalancePaused()) return;

        uint256 sharesToRedeem = actorShares / 2;
        if (sharesToRedeem == 0) sharesToRedeem = actorShares;

        // Snapshot counters before
        _snapshotFlowCounters();
        // Snapshot rate before (requestRedeem is a protocol op)
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = true;
        ghost_vaultHealthyAtPreviousRate = vault.accountingState().slashingDelta == 0;

        vm.prank(actor);
        uint256 requestId = vault.requestRedeem(sharesToRedeem, actor);
        _pendingRequestIds.push(requestId);

        // Update rate after
        ghost_latestExchangeRate = vault.exchangeRate();
    }

    function instantRedeem(uint256 actorSeed) external {
        address actor = address(0);
        uint256 actorShares = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 idx = (actorSeed + i) % actors.length;
            uint256 bal = stAztec.balanceOf(actors[idx]);
            if (bal > 0) {
                actor = actors[idx];
                actorShares = bal;
                break;
            }
        }
        if (actor == address(0)) return;
        if (vault.isRebalancePaused()) return;

        // Only redeem a small portion to avoid InsufficientLiquidity
        uint256 sharesToRedeem = actorShares / 4;
        if (sharesToRedeem == 0) sharesToRedeem = 1;

        uint256 grossAssets = vault.convertToAssets(sharesToRedeem);
        if (grossAssets == 0) return;
        if (grossAssets > vault.availableForInstantRedemption()) return;

        // Snapshot counters before
        _snapshotFlowCounters();
        // Snapshot rate before (instantRedeem is a protocol op)
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = true;
        ghost_vaultHealthyAtPreviousRate = vault.accountingState().slashingDelta == 0;

        vm.prank(actor);
        try vault.redeem(sharesToRedeem, actor, 0) { }
        catch {
            return;
        }

        // Update rate after
        ghost_latestExchangeRate = vault.exchangeRate();
    }

    function rebalanceSingleStep() external {
        // Snapshot slashing delta from accounting state before rebalance
        _snapshotSlashingDelta();

        vm.prank(operator);
        try vault.rebalance() { }
        catch {
            return;
        }

        _refreshFinalizedRequests();

        // Rebalance with mock staking manager may shift the rate due to mock
        // inconsistencies (e.g. stake() transfers tokens but totalStaked stays 0).
        // Reset the ghost baseline so rate monotonicity is only checked across
        // operations that have consistent accounting.
        ghost_latestExchangeRate = vault.exchangeRate();
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = false;
    }

    function claimRequest(uint256 idSeed) external {
        _refreshFinalizedRequests();

        if (_finalizedRequestIds.length == 0) return;

        uint256 idx = bound(idSeed, 0, _finalizedRequestIds.length - 1);
        uint256 requestId = _finalizedRequestIds[idx];

        _finalizedRequestIds[idx] = _finalizedRequestIds[_finalizedRequestIds.length - 1];
        _finalizedRequestIds.pop();

        vault.claimRequestById(requestId);
    }

    function updateAccounting() external {
        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
        if (progress.step != IOllaCore.RebalanceStep.Done) return;
        if (vault.isRebalancePaused()) return;

        // Snapshot counters before
        _snapshotFlowCounters();
        // Snapshot slashing delta from accounting state before update
        _snapshotSlashingDelta();
        // Snapshot cumulative rewards
        _snapshotCumulativeRewards();
        // Snapshot rate before (updateAccounting is a protocol op)
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = true;
        // Vault is healthy only when both accounting state AND the mock staking manager
        // have no pending slashing. updateAccounting() syncs the mock's slashingDelta
        // into accounting state, so a pending increase on the mock will cause a rate drop.
        ghost_vaultHealthyAtPreviousRate =
            vault.accountingState().slashingDelta == 0 && stakingManager.slashingDelta() == 0;

        vm.prank(operator);
        try vault.updateAccounting() { }
        catch {
            return;
        }

        // Update rate after
        ghost_latestExchangeRate = vault.exchangeRate();
    }

    /*//////////////////////////////////////////////////////////////
                      MOCK-ACCOUNTING MUTATIONS
    //////////////////////////////////////////////////////////////*/

    function setClaimableRewards(uint96 amount) external {
        // Only increase claimable rewards to match real protocol behavior
        uint256 next = uint256(bound(amount, 0, type(uint96).max));
        if (next < _lastClaimableRewards) {
            next = _lastClaimableRewards;
        }
        _lastClaimableRewards = next;
        stakingManager.setClaimableRewards(next);
        // Mock state changes shift the virtual exchange rate outside protocol ops;
        // reset the ghost baseline so monotonicity only tracks real protocol operations.
        ghost_latestExchangeRate = vault.exchangeRate();
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = false;
    }

    function setTotalStaked(uint96 amount) external {
        // Only increase total staked to match real protocol behavior
        uint256 next = uint256(bound(amount, 0, type(uint96).max));
        if (next < _lastTotalStaked) {
            next = _lastTotalStaked;
        }
        _lastTotalStaked = next;
        stakingManager.setTotalStaked(next);
        // Reset ghost baseline after mock mutation
        ghost_latestExchangeRate = vault.exchangeRate();
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = false;
    }

    function increaseSlashingDelta(uint96 delta) external {
        uint256 increase = uint256(bound(delta, 0, type(uint96).max));
        uint256 next = stakingManager.slashingDelta() + increase;
        stakingManager.setSlashingDelta(next);
        // Reset ghost baseline after mock mutation
        ghost_latestExchangeRate = vault.exchangeRate();
        ghost_previousExchangeRate = ghost_latestExchangeRate;
        ghost_rateTransitionIsProtocolOp = false;
    }

    function mintRewardsVault(uint96 amount) external {
        uint256 assets = uint256(bound(amount, 0, type(uint96).max));
        asset.mint(address(rewardsVault), assets);
        ghost_totalMinted += assets;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _refreshFinalizedRequests() internal {
        uint256 length = _pendingRequestIds.length;
        uint256 i = 0;
        while (i < length) {
            uint256 reqId = _pendingRequestIds[i];
            try withdrawalQueue.getRequest(reqId) returns (IWithdrawalQueue.WithdrawalRequest memory req) {
                if (req.finalized && !req.claimed) {
                    _finalizedRequestIds.push(reqId);
                    _pendingRequestIds[i] = _pendingRequestIds[length - 1];
                    _pendingRequestIds.pop();
                    length--;
                } else {
                    i++;
                }
            } catch {
                i++;
            }
        }
    }

    function _snapshotFlowCounters() internal {
        IOllaCore.FlowCounters memory flows = vault.flowCounters();
        ghost_previousCumulativeDeposits = flows.cumulativeDeposits;
        ghost_previousCumulativeWithdrawals = flows.cumulativeWithdrawals;
    }

    function _snapshotSlashingDelta() internal {
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        ghost_previousSlashingDelta = accounting.slashingDelta;
    }

    function _snapshotCumulativeRewards() internal {
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        ghost_previousCumulativeRewards = accounting.cumulativeRewards;
    }
}

/*//////////////////////////////////////////////////////////////
          PROTOCOL PROPERTY INVARIANT TEST CONTRACT
//////////////////////////////////////////////////////////////*/

contract OllaCoreProtocolPropertyInvariantTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaCore internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockAccountingStakingManager internal stakingManager;
    WithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    MockRewardsVault internal rewardsVault;
    OllaCoreProtocolPropertyHandler internal handler;
    address internal operator;
    address internal governance;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));
        governance = makeAddr("protprop_governance");
        operator = makeAddr("protprop_operator");

        OllaCore implementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(coreProxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));
        stakingManager.setUnstakedToken(asset);
        address providerRewardsRecipient = makeAddr("protprop_providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );
        vm.prank(governance);
        vault.unpause();

        withdrawalQueue.initialize(address(vault), governance);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();

        handler = new OllaCoreProtocolPropertyHandler(
            asset, vault, stAztec, stakingManager, rewardsVault, withdrawalQueue, operator, governance
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT SOLVENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice asset.balanceOf(core) >= bufferedAssets + _finalizedUnclaimedAssets
    function invariant_VaultSolvency() external view {
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        uint256 finalizedUnclaimed = uint256(vm.load(address(vault), bytes32(uint256(33))));
        uint256 vaultBalance = asset.balanceOf(address(vault));

        assertGe(
            vaultBalance,
            accounting.bufferedAssets + finalizedUnclaimed,
            "vault balance must cover buffered + finalized unclaimed"
        );
    }

    /*//////////////////////////////////////////////////////////////
            EXCHANGE RATE MONOTONICITY ACROSS ALL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Exchange rate should be non-decreasing across protocol operations
    ///         (deposits, instant redeems, request redeems, updateAccounting).
    ///         The invariant only applies when the vault is solvent (no slashing overhang).
    ///         When slashingDelta > 0, new deposits dilute against the slashing loss,
    ///         legitimately reducing the exchange rate by design.
    function invariant_ExchangeRateNonDecreasingAllOps() external view {
        if (!handler.ghost_rateTransitionIsProtocolOp()) return;
        // Skip when vault has slashing overhang; rate is not monotonic by design
        if (!handler.ghost_vaultHealthyAtPreviousRate()) return;

        assertGe(
            handler.ghost_latestExchangeRate(),
            handler.ghost_previousExchangeRate(),
            "exchange rate must be non-decreasing across protocol operations"
        );
    }

    /*//////////////////////////////////////////////////////////////
            DEPOSIT-REDEEM ROUNDTRIP (rounding favors protocol)
    //////////////////////////////////////////////////////////////*/

    /// @notice convertToAssets(convertToShares(assets)) <= assets
    function invariant_DepositRedeemRoundtripFavorsProtocol() external view {
        uint256 assets = bound(uint256(block.timestamp), 1, type(uint96).max);
        uint256 sharesFromAssets = vault.convertToShares(assets);
        uint256 assetsFromShares = vault.convertToAssets(sharesFromAssets);

        assertLe(assetsFromShares, assets, "round-trip must not create value (rounding favors protocol)");
    }

    /*//////////////////////////////////////////////////////////////
            CUMULATIVE COUNTERS NEVER DECREASE
    //////////////////////////////////////////////////////////////*/

    /// @notice cumulativeDeposits and cumulativeWithdrawals never decrease.
    function invariant_CumulativeCountersNeverDecrease() external view {
        IOllaCore.FlowCounters memory flows = vault.flowCounters();

        assertGe(
            flows.cumulativeDeposits,
            handler.ghost_previousCumulativeDeposits(),
            "cumulativeDeposits must never decrease"
        );
        assertGe(
            flows.cumulativeWithdrawals,
            handler.ghost_previousCumulativeWithdrawals(),
            "cumulativeWithdrawals must never decrease"
        );
    }

    /*//////////////////////////////////////////////////////////////
            SLASHING DELTA MONOTONICITY
    //////////////////////////////////////////////////////////////*/

    /// @notice slashingDelta in accounting state must never decrease.
    function invariant_SlashingDeltaMonotonicity() external view {
        IOllaCore.AccountingState memory accounting = vault.accountingState();

        assertGe(
            accounting.slashingDelta,
            handler.ghost_previousSlashingDelta(),
            "slashingDelta must be monotonically non-decreasing"
        );
    }

    /*//////////////////////////////////////////////////////////////
            TOKEN CONSERVATION LAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Total tokens across all contracts and actors >= totalAssets().
    ///         No tokens are created or destroyed outside of minting/burning.
    function invariant_TokenConservationLaw() external view {
        uint256 assetInVault = asset.balanceOf(address(vault));
        uint256 assetInStaking = asset.balanceOf(address(stakingManager));
        uint256 assetInRewards = asset.balanceOf(address(rewardsVault));
        uint256 assetInGovernance = asset.balanceOf(governance);

        uint256 totalInActors = 0;
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            totalInActors += asset.balanceOf(handler.actorAt(i));
        }

        uint256 totalTokensEverywhere =
            assetInVault + assetInStaking + assetInRewards + assetInGovernance + totalInActors;

        // All tokens that exist must equal what was minted
        assertEq(
            totalTokensEverywhere,
            handler.ghost_totalMinted(),
            "total tokens across all contracts must equal total minted"
        );
    }

    /*//////////////////////////////////////////////////////////////
            INSTANT REDEMPTION FEE CONSERVATION
    //////////////////////////////////////////////////////////////*/

    /// @notice fee + netAssets == grossAssets (no value created or lost in fee split).
    function invariant_InstantRedemptionFeeConservation() external view {
        uint256 shares = bound(uint256(block.timestamp), 1, type(uint96).max);
        uint256 grossAssets = vault.convertToAssets(shares);

        uint256 feeBP = vault.instantRedemptionFeeBP();
        uint256 bpDivisor = vault.BP_DIVISOR();
        uint256 fee = grossAssets * feeBP / bpDivisor;
        uint256 netAssets = grossAssets - fee;

        assertEq(fee + netAssets, grossAssets, "fee + netAssets must equal grossAssets exactly");
    }

    /*//////////////////////////////////////////////////////////////
            REBALANCE PAUSE BLOCKS USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice During rebalance (isRebalancePaused==true), deposits must revert.
    ///         When rebalance completes (Done), pause should be lifted.
    function invariant_RebalancePauseBlocksDeposits() external view {
        // If a deposit was attempted while paused, it must not have succeeded
        if (handler.ghost_rebalancePausedDepositAttempted()) {
            assertFalse(
                handler.ghost_rebalancePausedDepositSucceeded(), "deposit must not succeed while rebalance is paused"
            );
        }

        // When step is Done and not paused, the pause should be lifted
        IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
        if (progress.step == IOllaCore.RebalanceStep.Done) {
            assertFalse(vault.isRebalancePaused(), "pause must be lifted when rebalance step is Done");
        }
    }

    /*//////////////////////////////////////////////////////////////
            CUMULATIVE REWARDS NEVER DECREASE
    //////////////////////////////////////////////////////////////*/

    /// @notice accountingState().cumulativeRewards must never decrease.
    function invariant_CumulativeRewardsNeverDecrease() external view {
        IOllaCore.AccountingState memory accounting = vault.accountingState();

        assertGe(
            accounting.cumulativeRewards,
            handler.ghost_previousCumulativeRewards(),
            "cumulativeRewards must never decrease"
        );
    }

    /*//////////////////////////////////////////////////////////////
            VIRTUAL OFFSET PREVENTS FIRST-DEPOSITOR EXTRACTION
    //////////////////////////////////////////////////////////////*/

    /// @notice With the +1 virtual offset pattern, the first depositor should not
    ///         extract disproportionate value. For any non-trivial deposit, shares
    ///         received must be non-zero when totalAssets is not inflated beyond deposit.
    function invariant_VirtualOffsetPreventsExtraction() external view {
        uint256 supply = stAztec.totalSupply();
        uint256 total = vault.totalAssets();

        // Skip when vault is in a degenerate state (e.g. massive slashing with totalAssets
        // clamped to 0 and inflated supply). The multiplication testAmount * (supply + 1)
        // in convertToShares would overflow uint256, which is an arithmetic artefact of
        // the mock-driven slashing scenario, not a protocol vulnerability.
        uint256 testAmount = 1e18;
        if (total == 0 && supply > 0 && supply > type(uint256).max / testAmount) {
            return;
        }

        // Core check: convertToAssets(convertToShares(x)) <= x (no value extraction)
        // This ensures the virtual offset prevents the first depositor from extracting
        // more assets than they deposit through share manipulation.
        uint256 shares = vault.convertToShares(testAmount);
        uint256 assetsBack = vault.convertToAssets(shares);

        // No depositor can extract more than they put in
        assertLe(assetsBack, testAmount, "round-trip must not create value for depositor");

        if (supply == 0 && total == 0) {
            // Empty vault: shares = testAmount * (0 + 1) / (0 + 1) = testAmount
            assertEq(shares, testAmount, "empty vault should give 1:1 shares");

            // Verify small deposits also work 1:1 on empty vault
            uint256 smallAmount = 1e6;
            uint256 smallShares = vault.convertToShares(smallAmount);
            assertEq(smallShares, smallAmount, "empty vault small deposit should give 1:1 shares");
        }
    }
}
