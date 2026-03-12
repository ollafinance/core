// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaCoreSafetyModuleBreakerTest
/// @notice Tests that the MockSafetyModule's configurable circuit breakers
///         work correctly when enabled, and verifies call-counting.
contract OllaCoreSafetyModuleBreakerTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                     RATE DROP BREAKER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable 500bps threshold, cause a 10% drop, verify pause.
    function test_RateDropBreaker_PausesOnLargeRateDrop() external {
        safetyModule.mockSetMinRateDropBps(500);

        // Seed a deposit and simulate staking to establish a rate with staked principal
        _performDeposit(alice, 100 * DECIMALS);
        stakingManager.setTotalStaked(80 * DECIMALS);
        core.updateAccounting();

        assertFalse(safetyModule.isPaused(), "safety module should not be paused before slashing");

        // Simulate a large slashing event (12.5% of staked principal => 10% of total)
        // setSlashingDelta also reduces totalStaked: 80 - 10 = 70
        stakingManager.setSlashingDelta(10 * DECIMALS);
        core.updateAccounting();

        assertTrue(safetyModule.isPaused(), "safety module should be paused after large rate drop");
        assertGt(safetyModule.checkRateDropCallCount(), 0, "checkRateDrop should have been called");
    }

    /// @notice Enable 500bps threshold, cause a small drop (< 5%), verify no pause.
    function test_RateDropBreaker_NoFalsePositive() external {
        safetyModule.mockSetMinRateDropBps(500);

        // Seed a deposit with staked principal
        _performDeposit(alice, 100 * DECIMALS);
        stakingManager.setTotalStaked(80 * DECIMALS);
        core.updateAccounting();

        // Small slashing (~1% of total assets). setSlashingDelta reduces totalStaked 80-1=79.
        stakingManager.setSlashingDelta(1 * DECIMALS);
        core.updateAccounting();

        assertFalse(safetyModule.isPaused(), "safety module should not be paused for small rate drop");
    }

    /*//////////////////////////////////////////////////////////////
                    QUEUE RATIO BREAKER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable 6000bps threshold, create 70% queue ratio, verify pause.
    function test_QueueRatioBreaker_PausesOnHighRatio() external {
        safetyModule.mockSetMaxQueueRatioBps(6_000);

        // Seed a deposit
        _performDeposit(alice, 100 * DECIMALS);
        core.updateAccounting();

        // Request withdrawal for 70% of assets so the queue ratio exceeds 60%
        uint256 shares = stAztec.balanceOf(alice);
        uint256 redeemShares = (shares * 70) / 100;
        vm.prank(alice);
        stAztec.approve(address(vault), redeemShares);
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);

        // Trigger accounting to invoke checkQueueRatio
        core.updateAccounting();

        assertTrue(safetyModule.isPaused(), "safety module should be paused when queue ratio >= 60%");
        assertGt(safetyModule.checkQueueRatioCallCount(), 0, "checkQueueRatio should have been called");
    }

    /*//////////////////////////////////////////////////////////////
                   ACCOUNTING LIVENESS BREAKER TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set max delay, warp past it, verify pause on next accounting.
    function test_AccountingLiveness_PausesWhenStale() external {
        // Seed a deposit first
        _performDeposit(alice, 100 * DECIMALS);
        core.updateAccounting();

        // Set liveness check: max delay 7 days from current timestamp
        safetyModule.mockSetAccountingLiveness(block.timestamp, 7 days);

        // Warp 8 days
        vm.warp(block.timestamp + 8 days);

        // updateAccounting calls checkAccountingLiveness which should trigger pause
        core.updateAccounting();

        assertTrue(safetyModule.isPaused(), "safety module should be paused when accounting is stale");
        assertGt(safetyModule.checkAccountingLivenessCallCount(), 0, "checkAccountingLiveness should have been called");
    }

    /*//////////////////////////////////////////////////////////////
                       DEPOSIT CAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set cap 1000e18, attempt deposit of 1001e18, expect rejection.
    function test_DepositCap_RejectsExcessiveDeposit() external {
        safetyModule.mockSetDepositCap(1000 * DECIMALS);

        // Attempt to deposit over the cap
        asset.mint(alice, 1001 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 1001 * DECIMALS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__DepositCapExceeded.selector, 1001 * DECIMALS, 0));
        vault.deposit(1001 * DECIMALS, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
                  WITHDRAWAL MINIMUM TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set minimum 1e18, attempt 0.5e18, expect revert.
    function test_WithdrawalMinimum_RejectsSmallWithdrawal() external {
        safetyModule.mockSetWithdrawalMinimum(1 * DECIMALS);

        // Seed a deposit so alice has shares
        _performDeposit(alice, 10 * DECIMALS);

        uint256 smallShares = DECIMALS / 2; // 0.5e18
        vm.prank(alice);
        stAztec.approve(address(vault), smallShares);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ISafetyModule.SafetyModule__BelowWithdrawalMinimum.selector, smallShares, DECIMALS)
        );
        vault.requestRedeem(smallShares, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                   CALL COUNTING VERIFICATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify updateAccounting invokes checkAccountingLiveness,
    ///         checkRateDrop, and checkQueueRatio.
    function test_UpdateAccounting_InvokesSafetyModuleChecks() external {
        _performDeposit(alice, 100 * DECIMALS);

        uint256 rateDropBefore = safetyModule.checkRateDropCallCount();
        uint256 queueRatioBefore = safetyModule.checkQueueRatioCallCount();
        uint256 livenessBefore = safetyModule.checkAccountingLivenessCallCount();

        core.updateAccounting();

        assertGt(safetyModule.checkRateDropCallCount(), rateDropBefore, "updateAccounting should call checkRateDrop");
        assertGt(
            safetyModule.checkQueueRatioCallCount(), queueRatioBefore, "updateAccounting should call checkQueueRatio"
        );
        assertGt(
            safetyModule.checkAccountingLivenessCallCount(),
            livenessBefore,
            "updateAccounting should call checkAccountingLiveness"
        );
    }

    /// @notice Verify rebalance invokes checkAccountingLiveness.
    function test_Rebalance_InvokesAccountingLivenessCheck() external {
        _performDeposit(alice, 100 * DECIMALS);
        core.updateAccounting();

        uint256 livenessBefore = safetyModule.checkAccountingLivenessCallCount();

        // Advance time past cooldown
        vm.warp(block.timestamp + 1 days);
        core.rebalance();

        assertGt(
            safetyModule.checkAccountingLivenessCallCount(),
            livenessBefore,
            "rebalance should call checkAccountingLiveness"
        );
    }
}
