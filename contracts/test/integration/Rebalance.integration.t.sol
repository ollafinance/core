// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract RebalanceIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                             TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    SafetyModule internal safetyModule;
    address internal governance;
    address internal admin;
    address internal guardian;
    address internal operator;
    address internal user;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        safetyModule =
            new SafetyModule(admin, guardian, address(core), address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days);
        operator = makeAddr("operator");
        user = makeAddr("user");

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setUnstakedToken(asset);

        withdrawalQueue.initialize(address(vault), governance, 180_000);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        vm.stopPrank();

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 amount) internal returns (uint256 shares) {
        asset.mint(owner, amount);
        vm.prank(owner);
        asset.approve(address(vault), amount);
        vm.prank(owner);
        shares = vault.deposit(amount, owner, 0);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares, address recipient)
        internal
        returns (uint256 requestId, uint256 assetsExpected)
    {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, recipient, owner);
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        assetsExpected = request.assetsExpected;
        return (requestId, assetsExpected);
    }

    function _mockZeroHarvest() internal {
        stakingManager.setHarvestedRewards(0);
    }

    function _mockZeroUnstaked() internal {
        stakingManager.setUnstakedAmount(0);
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_WithdrawalsBeforeStaking() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 withdrawalAmount = 40 * DECIMALS;
        uint256 targetBufferAmount = 10 * DECIMALS;

        _performDeposit(user, depositAmount);

        uint256 withdrawalShares = core.convertToShares(withdrawalAmount);
        _requestRedeem(user, withdrawalShares, user);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferAmount);

        _mockZeroHarvest();
        _mockZeroUnstaked();
        stakingManager.setStakeReturnAmount(32 * DECIMALS);

        vm.prank(operator);
        (uint256 harvested, uint256 finalized, uint256 staked, uint256 buffer) = core.rebalance();

        assertEq(harvested, 0, "harvested should be zero");
        assertEq(finalized, withdrawalAmount, "should finalize all pending withdrawals first");
        assertEq(staked, 32 * DECIMALS, "should stake 1 unit after withdrawals");
        assertEq(buffer, 28 * DECIMALS, "buffer should be 60 - 32 = 28");
    }

    function test_Rebalance_Idempotent() external {
        uint256 depositAmount = 100 * DECIMALS;

        _performDeposit(user, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(10 * DECIMALS);

        _mockZeroHarvest();
        _mockZeroUnstaked();

        vm.prank(operator);
        (uint256 h1, uint256 f1, uint256 s1, uint256 b1) = core.rebalance();

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(operator);
        (uint256 h2, uint256 f2, uint256 s2, uint256 b2) = core.rebalance();

        assertEq(h1, 0, "first harvest should be 0");
        assertEq(f1, 0, "first finalize should be 0");
        assertGt(s1, 0, "first stake should be > 0");
        assertEq(h2, 0, "second harvest should be 0");
        assertEq(f2, 0, "second finalize should be 0");
        assertEq(s2, 0, "second stake should be 0 (already staked surplus)");
        assertEq(b2, b1, "buffer should remain same");
    }

    function test_Rebalance_QueueDrainsWithSufficientLiquidity() external {
        uint256 depositPerUser = 50 * DECIMALS;
        uint256 withdrawPerUser = 20 * DECIMALS;

        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        address[3] memory users = [user, user2, user3];
        uint256 expectedPending;
        for (uint256 i; i < users.length; ++i) {
            _performDeposit(users[i], depositPerUser);
            uint256 shares = core.convertToShares(withdrawPerUser);
            (, uint256 assetsExpected) = _requestRedeem(users[i], shares, users[i]);
            expectedPending += assetsExpected;
        }

        _mockZeroHarvest();
        _mockZeroUnstaked();

        vm.prank(governance);
        core.setTargetBufferedAssets(100 * DECIMALS);

        uint256 totalPendingBefore = withdrawalQueue.totalPendingAssets();
        assertEq(totalPendingBefore, expectedPending, "should have expected pending assets");

        vm.prank(operator);
        core.rebalance();

        uint256 totalPendingAfter = withdrawalQueue.totalPendingAssets();
        assertEq(totalPendingAfter, 0, "queue should be empty after draining");
    }

    function test_Rebalance_FullFlow() external {
        uint256 harvestAmount = 5 * DECIMALS;
        uint256 unstakedAmount = 10 * DECIMALS;
        uint256 depositAmount = 100 * DECIMALS;
        uint256 withdrawalAmount = 30 * DECIMALS;
        uint256 targetBufferAmount = 20 * DECIMALS;

        _performDeposit(user, depositAmount);

        uint256 withdrawalShares = core.convertToShares(withdrawalAmount);
        _requestRedeem(user, withdrawalShares, user);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferAmount);

        // Set staked principal in accounting to cover the unstaked funds that will be pulled.
        // getUnstakedFunds() returns exitAmount which is subtracted from stakedPrincipal,
        // so stakedPrincipal must be >= exitAmount to avoid underflow.
        stakingManager.setTotalStaked(unstakedAmount);
        vm.prank(operator);
        core.updateAccounting();

        stakingManager.setHarvestedRewards(harvestAmount);
        stakingManager.setUnstakedAmount(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);
        stakingManager.setStakeReturnAmount(32 * DECIMALS);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(operator);
        (uint256 harvested, uint256 finalized, uint256 staked, uint256 buffer) = core.rebalance();

        assertEq(harvested, harvestAmount, "harvest mismatch");
        assertEq(finalized, withdrawalAmount, "finalize mismatch");
        assertEq(staked, 32 * DECIMALS, "stake mismatch");
        // Buffer = deposit(100) + harvest(5) + unstaked(10) - finalized(30) - staked(32) = 53
        assertEq(buffer, 53 * DECIMALS, "final buffer mismatch");
    }

    function test_Rebalance_MultiCallAccountingConsistency() external {
        uint256 depositAmount = 200 * DECIMALS;
        uint256 withdrawalAmount = 60 * DECIMALS;
        uint256 targetBufferAmount = 20 * DECIMALS;

        _performDeposit(user, depositAmount);

        uint256 withdrawalShares = core.convertToShares(withdrawalAmount);
        _requestRedeem(user, withdrawalShares, user);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferAmount);

        _mockZeroHarvest();
        _mockZeroUnstaked();
        stakingManager.setStakeReturnAmount(120 * DECIMALS);
        stakingManager.setTotalStaked(120 * DECIMALS);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;
        uint256[6] memory gasOptions = [uint256(160_000), 170_000, 180_000, 190_000, 200_000, 210_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success,) = address(core).call{ gas: gasOptions[i] }(abi.encodeCall(core.rebalance, ()));
            if (!success) {
                continue;
            }
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step != IOllaCore.RebalanceStep.Done) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for partial rebalance");

        vm.revertToState(snapshotId);
        vm.prank(operator);
        core.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertTrue(progressAfter.step != IOllaCore.RebalanceStep.Done, "rebalance should not finish under low gas");

        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            vm.prank(operator);
            core.rebalance();
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.Done) {
                break;
            }
        }

        IOllaCore.RebalanceProgress memory progressFinal = core.rebalanceProgress();
        assertEq(uint256(progressFinal.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete");

        IOllaCore.AccountingState memory accounting = core.accountingState();
        assertEq(withdrawalQueue.totalPendingAssets(), 0, "withdrawal queue should be empty");
        assertEq(vault.bufferedAssets(), targetBufferAmount, "buffer should match target after rebalance");
        assertEq(accounting.stakedPrincipal, 120 * DECIMALS, "staked principal should match stake total");
        assertEq(
            vault.bufferedAssets() + accounting.stakedPrincipal,
            depositAmount - withdrawalAmount,
            "buffered + staked should match remaining assets"
        );
    }

    function test_Rebalance_EmitsCorrectEvents() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(user, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(10 * DECIMALS);

        _mockZeroHarvest();
        _mockZeroUnstaked();
        stakingManager.setStakeReturnAmount(64 * DECIMALS);

        vm.prank(operator);
        core.rebalance();

        vm.recordLogs();
        vm.prank(operator);
        core.rebalance();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        bool found;
        uint256 eventStaked;
        uint256 eventBuffer;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == topic) {
                (,, eventStaked, eventBuffer) = abi.decode(entries[i].data, (uint256, uint256, uint256, uint256));
                found = true;
                break;
            }
        }

        assertTrue(found, "Rebalanced event should be emitted");
        assertEq(eventStaked, 26 * DECIMALS, "staked amount mismatch");
        assertEq(eventBuffer, 10 * DECIMALS, "buffer mismatch");
    }

    /*//////////////////////////////////////////////////////////////
             END-TO-END OPERATOR CACHE -> ACCOUNTING -> REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Tests the full flow: fresh mock state -> accounting succeeds -> rebalance succeeds ->
    ///         stale state -> accounting reverts -> rebalance self-heals -> accounting succeeds again.
    function test_EndToEnd_OperatorCacheToAccountingToRebalance() external {
        uint256 depositAmount = 50 * DECIMALS;
        _performDeposit(user, depositAmount);

        // 1. Set mock cached state with realistic values
        //    withdrawableUnstakes = 0 so rebalance PullUnstaked step advances (hasExitableUnstakes = false)
        uint256 stakedPrincipal = 20 * DECIMALS;
        uint256 slashing = 2 * DECIMALS;
        uint256 pending = 5 * DECIMALS;
        uint256 claimable = 4 * DECIMALS;
        uint256 rewards = 6 * DECIMALS;

        stakingManager.setTotalStaked(stakedPrincipal);
        stakingManager.setSlashingDelta(slashing);
        stakingManager.setPendingUnstakes(pending);
        stakingManager.setWithdrawableUnstakes(0);
        stakingManager.setClaimableRewards(claimable);
        stakingManager.setHarvestedRewards(rewards);

        // 2. updateAccounting() should succeed with fresh state
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfterAccounting = core.latestReport();
        assertGt(reportAfterAccounting.timestamp, 0, "accounting should update timestamp");

        IOllaCore.AccountingState memory accounting = core.accountingState();
        assertEq(accounting.slashingDelta, slashing, "slashing delta persisted in accounting");
        assertEq(accounting.claimableRewards, claimable, "claimable rewards persisted");

        // 3. Rebalance should succeed -- harvest step pulls rewards into buffer
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(operator);
        (uint256 rewardsDelta,,,) = core.rebalance();
        assertEq(rewardsDelta, rewards, "rebalance should harvest rewards");

        IOllaCore.AccountingState memory accountingAfterRebalance = core.accountingState();
        assertEq(accountingAfterRebalance.cumulativeRewards, rewards, "cumulative rewards updated after rebalance");

        // 4. Set a short max age and warp past it to make state stale
        //    Also ensure we advance past the rebalance cooldown (1 hour)
        uint256 shortMaxAge = 30;
        stakingManager.setAttesterStateMaxAge(shortMaxAge);
        (uint256 lastUpdated,,) = stakingManager.getAttesterStateLiveness();

        {
            IOllaCore.LatestReport memory rpt = core.latestReport();
            uint256 minWarp = rpt.timestamp + 1 hours + 1;
            uint256 staleWarp = lastUpdated + shortMaxAge + 1;
            vm.warp(minWarp > staleWarp ? minWarp : staleWarp);
        }

        // 5. Verify updateAccounting() reverts with stale data
        vm.expectRevert(
            abi.encodeWithSelector(
                IStakingManager.StakingManager__AttesterStateStale.selector, lastUpdated, shortMaxAge
            )
        );
        vm.prank(operator);
        core.updateAccounting();

        // 6. Rebalance self-heals -- ComputeAttesterState step refreshes the stale state
        vm.prank(operator);
        core.rebalance();

        // Verify the attester state is no longer stale after rebalance
        (uint256 updatedAt,, bool isStale) = stakingManager.getAttesterStateLiveness();
        assertEq(updatedAt, block.timestamp, "attester state should be refreshed by rebalance");
        assertFalse(isStale, "attester state should not be stale after rebalance self-heal");

        // 7. After rebalance self-healed the state, updateAccounting() should also succeed
        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfterRefresh = core.latestReport();
        assertGt(
            reportAfterRefresh.timestamp,
            reportAfterAccounting.timestamp,
            "accounting timestamp should advance after rebalance self-healed state"
        );
    }
}
