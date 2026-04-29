// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MaliciousReentrantStakingManager } from "test/mocks/MaliciousReentrantStakingManager.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

// `InconsistentWithdrawalQueue` and `MismatchWithdrawalQueue` test contracts were removed when
// the queue was folded into OllaVault: their purpose was to simulate a malicious external queue
// returning state-inconsistent values, but with the queue internalised the same checks now guard
// purely-internal bookkeeping and cannot fire from outside. The OllaVault__FinalizeInconsistent
// guard remains on internal arithmetic only.

/// @notice MockAccountingStakingManager override that can optionally keep `totalStakedAmount` in
///         sync with the tokens it actually receives, so `totalStaked()` reflects real stake flow
///         after a rebalance. The base mock leaves `totalStakedAmount` as a purely orthogonal
///         knob, which breaks pull-model tests that expect `core.totalAssets()` (now a live
///         read-through of `stakingManager.totalStaked()`) to reflect post-rebalance state.
/// @dev Tracking is opt-in via `setTrackStakedAmount(true)` to preserve compatibility with the
///      majority of rebalance tests that prime `totalStakedAmount` explicitly via
///      `setTotalStaked()` as an oracle value and would double-count if stake() also incremented
///      it.
contract MockStakeTrackingStakingManager is MockAccountingStakingManager {
    bool public trackStakedAmount;

    function setTrackStakedAmount(bool enabled) external {
        trackStakedAmount = enabled;
    }

    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        uint256 actualAmount = amount;
        if (useStakeReturnAmount) {
            actualAmount = stakeReturnAmount;
            if (!allowStakeReturnExceeds && actualAmount > amount) {
                actualAmount = amount;
            }
        }
        if (actualAmount == 0) {
            return 0;
        }
        if (address(rewardsToken) == address(0)) {
            return 0;
        }
        uint256 transferAmount = actualAmount > amount ? amount : actualAmount;
        if (transferAmount != 0) {
            rewardsToken.transferFrom(msg.sender, address(this), transferAmount);
        }
        if (trackStakedAmount) {
            totalStakedAmount += transferAmount;
        }
        return actualAmount;
    }
}

contract OllaCoreRebalanceTest is Test {
    using stdStorage for StdStorage;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsDelta(uint256 delta);
    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);
    event UnstakedFundsClaimed(uint256 amount);
    event WithdrawalFinalized(uint256 available, uint256 used);
    event UnstakeInitiated(uint256 requested, uint256 initiated);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant DEFAULT_REBALANCE_GAS_THRESHOLD = 180_000;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakeTrackingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakeTrackingStakingManager();
        operator = makeAddr("operator");
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        // Configure staking manager to mint rewards directly to rewards vault
        address providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");

        // Advance past the 1-hour rebalance cooldown initialised in OllaCore.initialize()
        vm.warp(block.timestamp + 1 hours);
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

    function _requestWithdrawal(address owner, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
        return requestId;
    }

    /*//////////////////////////////////////////////////////////////
                           GAS THRESHOLD
    //////////////////////////////////////////////////////////////*/

    function test_DefaultRebalanceGasThreshold() external view {
        assertEq(core.rebalanceGasThreshold(), DEFAULT_REBALANCE_GAS_THRESHOLD, "default gas threshold");
    }

    function test_RevertWhen_NonAdminSetsRebalanceGasThreshold() external {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        core.setRebalanceGasThreshold(200_000);
    }

    function test_RevertWhen_OperatorWithoutAdminSetsRebalanceGasThreshold() external {
        address otherOperator = makeAddr("otherOperator");

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, otherOperator));
        vm.prank(otherOperator);
        core.setRebalanceGasThreshold(200_000);
    }

    function test_SetRebalanceGasThreshold_UpdatesThreshold() external {
        uint256 newThreshold = 240_000;

        vm.prank(governance);
        core.setRebalanceGasThreshold(newThreshold);

        assertEq(core.rebalanceGasThreshold(), newThreshold, "core gas threshold updated");
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_HarvestsRewardsAndUpdatesCumulativeRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        IOllaCore.AccountingState memory accountingBefore = core.accountingState();

        // Expected buffer after rebalance includes rewards pulled from rewards vault
        uint256 expectedBuffer = vault.bufferedAssets() + rewardAmount;

        vm.prank(governance);
        core.setTargetBufferedAssets(expectedBuffer);

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.harvestRewards, ()));
        vm.expectEmit(true, true, true, true, address(core));
        emit RewardsDelta(rewardAmount);
        vm.expectEmit(true, true, true, true, address(core));
        emit Rebalanced(rewardAmount, 0, 0, expectedBuffer);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.AccountingState memory accountingAfter = core.accountingState();
        assertEq(
            accountingAfter.cumulativeRewards,
            accountingBefore.cumulativeRewards + rewardAmount,
            "cumulative rewards updated"
        );
    }

    function test_Rebalance_ZeroRewardsEmitsAndDoesNotUpdateCumulativeRewards() external {
        uint256 depositAmount = 8 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 firstReward = 3 * DECIMALS;
        stakingManager.setHarvestedRewards(firstReward);
        vm.prank(operator);
        core.rebalance();

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        uint256 expectedBuffer = vault.bufferedAssets();

        vm.prank(governance);
        core.setTargetBufferedAssets(expectedBuffer);

        stakingManager.setHarvestedRewards(0);

        IOllaCore.AccountingState memory accountingBefore = core.accountingState();

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.harvestRewards, ()));
        vm.expectEmit(true, true, true, true, address(core));
        emit RewardsDelta(0);
        vm.expectEmit(true, true, true, true, address(core));
        emit Rebalanced(0, 0, 0, expectedBuffer);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.AccountingState memory accountingAfter = core.accountingState();
        assertEq(accountingAfter.cumulativeRewards, accountingBefore.cumulativeRewards, "cumulative rewards unchanged");
    }

    function test_Rebalance_PullUnstakedFunds_IncreasesBuffer() external {
        uint256 unstakedAmount = 5 * DECIMALS;

        // Deposit and stake first so that stakedPrincipal >= exitAmount
        // (the mock returns exitAmount = receivedAmount, and the core code
        // decrements stakedPrincipal by exitAmount).
        _performDeposit(alice, unstakedAmount);
        vm.prank(governance);
        core.setTargetBufferedAssets(0);
        stakingManager.setStakeReturnAmount(unstakedAmount);
        stakingManager.setTotalStaked(unstakedAmount);
        vm.prank(operator);
        core.rebalance();

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        // Now configure unstaked funds for the next rebalance
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);
        stakingManager.setStakeReturnAmount(0);

        uint256 expectedBuffer = vault.bufferedAssets() + unstakedAmount;

        vm.prank(governance);
        core.setTargetBufferedAssets(expectedBuffer);

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.getUnstakedFunds, ()));
        vm.expectEmit(true, true, true, true, address(core));
        emit UnstakedFundsClaimed(unstakedAmount);

        vm.prank(operator);
        core.rebalance();

        assertEq(vault.bufferedAssets(), expectedBuffer, "buffered assets increased");
    }

    function test_Rebalance_PullUnstakedFunds_NoOp() external {
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(0);

        uint256 bufferBefore = vault.bufferedAssets();

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.getUnstakedFunds, ()));
        vm.prank(operator);
        core.rebalance();

        assertEq(vault.bufferedAssets(), bufferBefore, "buffered assets unchanged");
    }

    function test_Rebalance_PullUnstakedFunds_CapsExitAmountToStakedPrincipal() external {
        uint256 stakedAmount = 5 * DECIMALS;
        uint256 unstakedAmount = 8 * DECIMALS; // exitAmount > stakedPrincipal

        // Deposit and stake to establish stakedPrincipal
        _performDeposit(alice, stakedAmount);
        vm.prank(governance);
        core.setTargetBufferedAssets(0);
        stakingManager.setStakeReturnAmount(stakedAmount);
        stakingManager.setTotalStaked(stakedAmount);
        vm.prank(operator);
        core.rebalance();

        assertEq(core.accountingState().stakedPrincipal, stakedAmount, "stakedPrincipal after stake");

        // Advance past cooldown
        vm.warp(block.timestamp + 1 hours);

        // Configure unstaked funds where exitAmount > stakedPrincipal.
        // This simulates a scenario where the rollup returns more than tracked
        // (e.g. rollup upgrade or accounting drift after slashing).
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        stakingManager.setUnstakedExitAmountOverride(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);
        stakingManager.setStakeReturnAmount(0);
        // After exits, nothing remains staked on the rollup
        stakingManager.setTotalStaked(0);

        vm.prank(governance);
        core.setTargetBufferedAssets(unstakedAmount);

        // Without the cap, this would revert with arithmetic underflow
        // because exitAmount (8e18) > stakedPrincipal (5e18).
        vm.prank(operator);
        core.rebalance();

        // _updateAccountingInternal runs at end and resets stakedPrincipal
        // from totalStaked() (now 0). The key assertion is that we didn't revert.
        IOllaCore.AccountingState memory accountingAfter = core.accountingState();
        assertEq(accountingAfter.stakedPrincipal, 0, "stakedPrincipal zeroed");
    }

    function test_Rebalance_FinalizeWithdrawals_ConsumesBuffer() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 withdrawalShares = 6 * DECIMALS;
        uint256 targetBufferedAssets = 4 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        uint256 bufferBefore = vault.bufferedAssets();
        uint256 bufferAfterFinalize = bufferBefore - request.assetsExpected;
        uint256 expectedStaked = bufferAfterFinalize - targetBufferedAssets;

        vm.expectEmit(true, true, true, true, address(core));
        emit RewardsDelta(0);
        vm.expectEmit(true, true, true, true, address(core));
        emit WithdrawalFinalized(bufferBefore, request.assetsExpected);
        vm.expectEmit(true, true, true, true, address(core));
        emit Rebalanced(0, request.assetsExpected, expectedStaked, bufferAfterFinalize);

        vm.prank(operator);
        core.rebalance();

        assertEq(vault.bufferedAssets(), bufferAfterFinalize, "buffered assets reduced by finalize");
    }

    function test_Rebalance_FinalizeWithdrawals_QueueDrains() external {
        uint256 depositAmount = 20 * DECIMALS;
        uint256 withdrawalShares = 5 * DECIMALS;

        _performDeposit(alice, depositAmount);
        _requestWithdrawal(alice, withdrawalShares);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        vm.prank(operator);
        core.rebalance();

        assertEq(vault.pendingWithdrawalAssets(), 0, "pending queue drained");
    }

    function test_Rebalance_FinalizeWithdrawals_NoLiquidityNoEvent() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 targetBuffered = 0;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBuffered);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setTotalStaked(depositAmount);

        vm.prank(operator);
        core.rebalance();

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        _requestWithdrawal(alice, depositAmount);

        vm.recordLogs();
        vm.prank(operator);
        core.rebalance();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 topic = keccak256("WithdrawalFinalized(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(core) && entries[i].topics[0] == topic) {
                found = true;
                break;
            }
        }

        assertFalse(found, "should not emit WithdrawalFinalized without liquidity");
        assertEq(vault.pendingWithdrawalAssets(), depositAmount, "pending assets unchanged");
        assertEq(vault.bufferedAssets(), targetBuffered, "buffer unchanged");
    }

    function test_Rebalance_PullUnstaked_AdvancesWithPendingExits() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 withdrawalShares = 4 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(depositAmount);

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        // Set hasFinalizedUnstakes=true to indicate pending exits exist
        stakingManager.setWithdrawableUnstakes(1);

        uint256 bufferBefore = vault.bufferedAssets();

        vm.prank(operator);
        core.rebalance();

        // PullUnstaked no longer blocks — rebalance advances past it and completes
        IOllaCore.RebalanceProgress memory progressAfterFirst = core.rebalanceProgress();
        assertEq(
            uint256(progressAfterFirst.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should advance past PullUnstaked even with pending exits"
        );

        // Pending exits had no unstaked funds to pull (unstakedAmount=0), so buffer is
        // only reduced by the withdrawal finalization against the existing buffer.
        assertEq(
            vault.bufferedAssets(), bufferBefore - request.assetsExpected, "buffer reduced by finalized withdrawal"
        );
        assertEq(vault.pendingWithdrawalAssets(), 0, "pending assets finalized in same cycle");
    }

    /*//////////////////////////////////////////////////////////////
                        REBALANCE PARTIAL PROGRESS
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_PullUnstaked_AlwaysCompletes() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 rewardAmount = 3 * DECIMALS;

        _performDeposit(alice, depositAmount);
        stakingManager.setHarvestedRewards(rewardAmount);

        // Set target buffer high so nothing gets staked — allows verifying buffer amount
        uint256 expectedBuffer = vault.bufferedAssets() + rewardAmount;
        vm.prank(governance);
        core.setTargetBufferedAssets(expectedBuffer);

        // PullUnstaked is O(1) — just a balance transfer — so it always completes
        // regardless of gas. Verify it advances past PullUnstaked in a single call.
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertTrue(
            uint256(progressAfter.step) != uint256(IOllaCore.RebalanceStep.PullUnstaked),
            "rebalance should always advance past PullUnstaked (O(1) step)"
        );
        assertEq(rewardsDelta, rewardAmount, "rewards delta should return harvested amount");
        assertEq(resultingBuffer, expectedBuffer, "buffer should include harvested rewards");
    }

    function test_Rebalance_ReturnsPartialProgress_WhenGasStopsAtFinalizeWithdrawals() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 rewardAmount = 4 * DECIMALS;
        uint256 unstakedAmount = 1 * DECIMALS;

        // Deposit and stake first so stakedPrincipal >= exitAmount
        _performDeposit(alice, depositAmount);
        vm.prank(governance);
        core.setTargetBufferedAssets(0);
        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setTotalStaked(depositAmount);
        vm.prank(operator);
        core.rebalance();

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        // Set up the actual test scenario
        stakingManager.setHarvestedRewards(rewardAmount);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);
        stakingManager.setGasBurnTarget(60_000);

        uint256 expectedBuffer = vault.bufferedAssets() + rewardAmount + unstakedAmount;

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;

        for (uint256 gasLimit = 250_000; gasLimit <= 800_000; gasLimit += 25_000) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success, bytes memory data) = address(core).call{ gas: gasLimit }(abi.encodeCall(core.rebalance, ()));
            if (!success) {
                continue;
            }

            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.FinalizeWithdrawals) {
                (
                    uint256 loopRewardsDelta,
                    uint256 loopFinalizedAmount,
                    uint256 loopStakedAmount,
                    uint256 loopResultingBuffer
                ) = abi.decode(data, (uint256, uint256, uint256, uint256));
                if (loopRewardsDelta == rewardAmount && loopFinalizedAmount == 0 && loopStakedAmount == 0) {
                    selectedGas = gasLimit;
                    assertEq(loopResultingBuffer, expectedBuffer, "buffer should include harvested rewards");
                    break;
                }
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for finalize stop");

        vm.revertToState(snapshotId);
        vm.prank(operator);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            core.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "rebalance should stop at finalize withdrawals"
        );
        assertEq(rewardsDelta, rewardAmount, "rewards delta should return harvested amount");
        assertEq(finalizedAmount, 0, "finalized amount should be zero on partial progress");
        assertEq(stakedAmount, 0, "staked amount should be zero on partial progress");
        assertEq(resultingBuffer, expectedBuffer, "buffer should include harvested rewards");
    }

    function test_Rebalance_LowGas_PullUnstakedResumesAcrossCalls() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 unstakedAmount = 3 * DECIMALS;

        // Deposit and stake first so stakedPrincipal >= exitAmount
        _performDeposit(alice, depositAmount);
        vm.prank(governance);
        core.setTargetBufferedAssets(0);
        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setTotalStaked(depositAmount);
        vm.prank(operator);
        core.rebalance();

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        // Now configure unstaked funds for the next rebalance
        stakingManager.setHarvestedRewards(0);
        stakingManager.setStakeReturnAmount(0);
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        stakingManager.setGasBurnTarget(90_000);
        asset.mint(address(stakingManager), unstakedAmount);

        uint256 expectedBuffer = vault.bufferedAssets() + unstakedAmount;

        vm.prank(governance);
        core.setTargetBufferedAssets(expectedBuffer);

        vm.prank(operator);
        core.rebalance{ gas: 400_000 }();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "rebalance should pause after pull unstaked under low gas"
        );

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressFinal = core.rebalanceProgress();
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should complete after follow-up"
        );
    }

    function test_Rebalance_FinalizeWithdrawals_BoundedGasProgresses() external {
        uint256 totalRequests = 200;
        uint256 requestShares = 1 * DECIMALS;
        uint256 depositAmount = totalRequests * requestShares;

        _performDeposit(alice, depositAmount);

        for (uint256 i = 0; i < totalRequests; i++) {
            _requestWithdrawal(alice, requestShares);
        }

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);

        uint256 totalPendingBefore = vault.pendingWithdrawalAssets();
        if (vault.bufferedAssets() < totalPendingBefore) {
            uint256 bufferGap = totalPendingBefore - vault.bufferedAssets();
            asset.mint(address(vault), bufferGap);
            vm.prank(governance);
            vault.reconcileBufferedAssets();
        }

        uint256 bufferBefore = vault.bufferedAssets();
        uint256 snapshotId = vm.snapshotState();

        uint256 selectedGas;
        uint256 finalizedObserved;
        uint256 bufferObserved;
        uint256[6] memory gasOptions = [uint256(120_000), 140_000, 160_000, 180_000, 200_000, 220_000];

        for (uint256 i = 0; i < gasOptions.length; i++) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success, bytes memory data) =
                address(core).call{ gas: gasOptions[i] }(abi.encodeCall(core.rebalance, ()));

            if (!success) {
                continue;
            }

            (, uint256 finalizedCandidate,, uint256 bufferCandidate) =
                abi.decode(data, (uint256, uint256, uint256, uint256));
            if (finalizedCandidate > 0 && finalizedCandidate < totalPendingBefore) {
                selectedGas = gasOptions[i];
                finalizedObserved = finalizedCandidate;
                bufferObserved = bufferCandidate;
                break;
            }
        }

        if (selectedGas == 0) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            core.rebalance();

            assertEq(vault.pendingWithdrawalAssets(), 0, "queue should drain in one call");
            assertEq(vault.bufferedAssets(), bufferBefore - totalPendingBefore, "buffer should drain");
            return;
        }

        vm.revertToState(snapshotId);
        vm.prank(operator);
        (, uint256 finalizedAmount,, uint256 bufferAfter) = core.rebalance{ gas: selectedGas }();

        assertEq(finalizedAmount, finalizedObserved, "finalized amount should match probe");
        assertEq(bufferAfter, bufferObserved, "buffer should match probe");
        assertEq(
            vault.pendingWithdrawalAssets(),
            totalPendingBefore - finalizedAmount,
            "pending assets should decrease by finalized amount"
        );
        assertEq(
            vault.bufferedAssets(),
            bufferBefore - finalizedAmount,
            "buffered assets should decrease by finalized amount"
        );

        for (uint256 i = 0; i < 50; i++) {
            vm.prank(operator);
            core.rebalance();
            if (vault.pendingWithdrawalAssets() == 0) {
                break;
            }
        }

        assertEq(vault.pendingWithdrawalAssets(), 0, "queue should drain after follow-up rebalance");
    }

    function test_Rebalance_Liveness_ZeroUnstakeReturn_Recovers() external {
        uint256 bufferAmount = 5 * DECIMALS;
        uint256 targetBufferedAssets = 20 * DECIMALS;

        asset.mint(address(vault), bufferAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);
        stakingManager.setUnstakeReturnAmount(0);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should advance when no unstake capacity"
        );
        assertEq(progressAfter.unstakeRemaining, 0, "unstake remaining should clear when no capacity");

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressFinal = core.rebalanceProgress();
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should remain done after recovery"
        );
    }

    function test_Rebalance_Liveness_ZeroUnstakeReturn_WithCapacity_DoesNotAdvance() external {
        uint256 bufferAmount = 5 * DECIMALS;
        uint256 targetBufferedAssets = 20 * DECIMALS;

        asset.mint(address(vault), bufferAmount);
        vm.prank(governance);
        vault.reconcileBufferedAssets();

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);
        stakingManager.setUnstakeReturnAmount(0);
        stakingManager.setActivatedAttesterCount(1);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.InitiateUnstake),
            "rebalance should stay in initiate unstake with capacity"
        );
        assertEq(
            progressAfter.unstakeRemaining,
            targetBufferedAssets - bufferAmount,
            "unstake remaining should persist when capacity exists"
        );
    }

    function test_Rebalance_Bounded_StateMachineCompletesAndEmitsOnce() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 withdrawalShares = 20 * DECIMALS;
        uint256 targetBufferedAssets = 10 * DECIMALS;
        uint256 rewardAmount = 5 * DECIMALS;
        uint256 unstakedAmount = 8 * DECIMALS;

        // Deposit and stake first so stakedPrincipal >= exitAmount
        _performDeposit(alice, depositAmount);
        vm.prank(governance);
        core.setTargetBufferedAssets(0);
        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setTotalStaked(depositAmount);
        vm.prank(operator);
        core.rebalance();

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        // Set up the actual test scenario
        _requestWithdrawal(alice, withdrawalShares);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(rewardAmount);
        stakingManager.setUnstakedToken(asset);
        stakingManager.setUnstakedAmount(unstakedAmount);
        asset.mint(address(stakingManager), unstakedAmount);
        stakingManager.setStakeReturnAmount(20 * DECIMALS);

        // Force the gas gate to always fail by writing `rebalanceGasThreshold`
        // directly to type(uint32).max. This bypasses the setter's 1M cap and
        // its whenRebalanceDone modifier. Any realistic call budget is now
        // below the gate, so the state machine deterministically parks at the
        // first gated step (FinalizeWithdrawals) regardless of optimizer
        // settings — the test no longer depends on a fragile gas-stipend sweep.
        uint32 defaultThreshold = core.rebalanceGasThreshold();
        _forceRebalanceGasThreshold(type(uint32).max);

        vm.recordLogs();
        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "rebalance should park at first gated step"
        );

        bytes32 rebalancedSelector = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        Vm.Log[] memory earlyLogs = vm.getRecordedLogs();
        bool earlyEmit;
        for (uint256 i; i < earlyLogs.length; ++i) {
            if (earlyLogs[i].topics[0] == rebalancedSelector) {
                earlyEmit = true;
                break;
            }
        }
        assertFalse(earlyEmit, "should not emit Rebalanced before completion");

        // Restore threshold so the remaining steps can proceed. vm.store
        // bypasses whenRebalanceDone (we are mid-rebalance here).
        _forceRebalanceGasThreshold(defaultThreshold);

        uint256 rebalancedEvents;
        uint256 maxIterations = 10;
        for (uint256 i; i < maxIterations; ++i) {
            vm.recordLogs();
            vm.prank(operator);
            core.rebalance();
            Vm.Log[] memory entries = vm.getRecordedLogs();
            for (uint256 j; j < entries.length; ++j) {
                if (entries[j].topics[0] == rebalancedSelector) {
                    rebalancedEvents += 1;
                }
            }
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.Done) {
                break;
            }
        }

        IOllaCore.RebalanceProgress memory progressFinal = core.rebalanceProgress();
        assertEq(uint256(progressFinal.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should finish");
        assertEq(progressFinal.stakeRemaining, 0, "stake remaining should clear");
        assertEq(progressFinal.unstakeRemaining, 0, "unstake remaining should clear");
        assertEq(rebalancedEvents, 1, "Rebalanced should emit once at completion");
    }

    /// @dev Overwrites OllaCore.rebalanceGasThreshold without going through the
    ///      setter to bypass the 1M cap and whenRebalanceDone modifier.
    ///      StdStorage resolves the packed slot from the getter so the helper
    ///      tracks layout changes automatically.
    function _forceRebalanceGasThreshold(uint32 value) internal {
        stdstore.target(address(core)).sig("rebalanceGasThreshold()").enable_packed_slots().checked_write(value);
        require(core.rebalanceGasThreshold() == value, "_forceRebalanceGasThreshold: slot layout drifted");
    }

    function test_Rebalance_NoOp_WhenNoRewardsNoUnstakedNoQueue() external {
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        uint256 bufferedBefore = vault.bufferedAssets();

        vm.expectEmit(true, true, true, true, address(core));
        emit RewardsDelta(0);
        vm.expectEmit(true, true, true, true, address(core));
        emit Rebalanced(0, 0, 0, bufferedBefore);

        vm.prank(operator);
        core.rebalance();

        assertEq(vault.bufferedAssets(), bufferedBefore, "buffered assets unchanged");
    }

    function test_Rebalance_Unstake_TargetBufferedAssetsShortfall_NoPending() external {
        uint256 bufferAmount = 10 * DECIMALS;
        uint256 targetBufferedAssets = 30 * DECIMALS;

        asset.mint(address(vault), bufferAmount);
        vm.prank(governance);
        vault.reconcileBufferedAssets();

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        uint256 shortfall = targetBufferedAssets - bufferAmount;

        vm.expectEmit(true, true, true, true, address(core));
        emit UnstakeInitiated(shortfall, shortfall);

        vm.prank(operator);
        core.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), shortfall, "unstake replenishes buffer");
    }

    function test_Rebalance_Unstake_PendingExceedsBuffer() external {
        uint256 pendingAssets = 25 * DECIMALS;

        stdstore.target(address(vault)).sig("pendingWithdrawalAssets()").checked_write(pendingAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.prank(operator);
        core.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets, "unstake initiated");
    }

    function test_Rebalance_Unstake_PendingPlusTargetBufferedAssets() external {
        uint256 pendingAssets = 25 * DECIMALS;
        uint256 targetBufferedAssets = 5 * DECIMALS;

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stdstore.target(address(vault)).sig("pendingWithdrawalAssets()").checked_write(pendingAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.prank(operator);
        core.rebalance();

        assertEq(
            stakingManager.lastUnstakeAmount(),
            pendingAssets + targetBufferedAssets,
            "unstake uses pending plus target buffer"
        );
    }

    function test_Rebalance_Unstake_NoOpWhenBufferCoversPending() external {
        uint256 bufferAmount = 30 * DECIMALS;
        uint256 redeemShares = 25 * DECIMALS;

        _performDeposit(alice, bufferAmount);
        _requestWithdrawal(alice, redeemShares);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.prank(operator);
        core.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), 0, "unstake not initiated");
    }

    function test_Rebalance_Unstake_PendingUnstakesReduceInitiation() external {
        uint256 pendingAssets = 30 * DECIMALS;
        uint256 pendingUnstakes = 12 * DECIMALS;

        stdstore.target(address(vault)).sig("pendingWithdrawalAssets()").checked_write(pendingAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(pendingUnstakes);

        vm.prank(operator);
        core.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets - pendingUnstakes, "unstake reduced by pending");
    }

    function test_Rebalance_Unstake_NoUnitRounding() external {
        uint256 pendingAssets = 210 * DECIMALS;

        stdstore.target(address(vault)).sig("pendingWithdrawalAssets()").checked_write(pendingAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        vm.expectEmit(true, true, true, true, address(core));
        emit UnstakeInitiated(pendingAssets, pendingAssets);

        vm.prank(operator);
        core.rebalance();

        assertEq(stakingManager.lastUnstakeAmount(), pendingAssets, "unstake uses requested amount");
    }

    /*//////////////////////////////////////////////////////////////
                             STAKE SURPLUS
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_StakeSurplus_UsesActualStakedAmount() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 targetBufferedAssets = 10 * DECIMALS;
        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        // Under pull-model accounting, core.accountingState().stakedPrincipal reads
        // stakingManager.totalStaked() live, so the mock must propagate the actual staked amount
        // into its own accounting rather than leaving totalStakedAmount as a static oracle.
        stakingManager.setTrackStakedAmount(true);

        uint256 actualStaked = 64 * DECIMALS;
        stakingManager.setStakeReturnAmount(actualStaked);

        IOllaCore.AccountingState memory accountingBefore = core.accountingState();
        uint256 bufferedBefore = vault.bufferedAssets();
        uint256 stakeable = bufferedBefore - targetBufferedAssets;
        uint256 expectedBufferAfter = bufferedBefore - actualStaked;
        uint256 expectedStakedPrincipal = accountingBefore.stakedPrincipal + actualStaked;

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.stake, (stakeable)));

        vm.prank(operator);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = core.rebalance();

        IOllaCore.AccountingState memory accountingAfter = core.accountingState();
        assertEq(stakedAmount, actualStaked, "staked amount uses staking manager return");
        assertEq(resultingBuffer, expectedBufferAfter, "resulting buffer uses actual staked");
        assertEq(vault.bufferedAssets(), expectedBufferAfter, "buffered assets reduced by actual staked");
        assertEq(
            accountingAfter.stakedPrincipal, expectedStakedPrincipal, "staked principal increased by actual staked"
        );
    }

    function test_Rebalance_StakeSurplus_NoStakeWhenBelowTarget() external {
        uint256 depositAmount = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 targetBufferedAssets = 10 * DECIMALS;
        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        IOllaCore.AccountingState memory accountingBefore = core.accountingState();
        uint256 bufferedBefore = vault.bufferedAssets();

        vm.expectEmit(true, true, true, true, address(core));
        emit Rebalanced(0, 0, 0, bufferedBefore);

        vm.prank(operator);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = core.rebalance();

        assertEq(stakedAmount, 0, "staked amount is zero when below target");
        assertEq(resultingBuffer, bufferedBefore, "buffer unchanged when below target");
        assertEq(core.accountingState().stakedPrincipal, accountingBefore.stakedPrincipal, "staked principal unchanged");
    }

    function test_Rebalance_Liveness_ZeroStakeReturn_Recovers() external {
        uint256 depositAmount = 30 * DECIMALS;
        uint256 targetBufferedAssets = 10 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should advance when no stake capacity"
        );
        assertEq(progressAfter.stakeRemaining, 0, "stake remaining should clear when no capacity");

        // Advance past cooldown so a new rebalance cycle can start
        vm.warp(block.timestamp + 1 hours);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressFinal = core.rebalanceProgress();
        assertEq(
            uint256(progressFinal.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should remain done after recovery"
        );
    }

    function test_Rebalance_StakeSurplus_RevertsWhenStakedExceedsStakeable() external {
        uint256 depositAmount = 20 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 targetBufferedAssets = 10 * DECIMALS;
        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);

        uint256 bufferedBefore = vault.bufferedAssets();
        uint256 stakeable = bufferedBefore - targetBufferedAssets;

        stakingManager.setStakeReturnAmount(stakeable + 1);
        stakingManager.setAllowStakeReturnExceeds(true);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__StakeFailed.selector, stakeable + 1));
        vm.prank(operator);
        core.rebalance();
    }

    function test_Rebalance_StakeSurplus_ReclampsStaleStakeRemainingOnResume() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 initialStakeAmount = 40 * DECIMALS;
        uint256 withdrawalShares = 60 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(initialStakeAmount);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfterPartialStake = core.rebalanceProgress();
        assertEq(
            uint256(progressAfterPartialStake.step),
            uint256(IOllaCore.RebalanceStep.StakeSurplus),
            "rebalance should pause in stake surplus"
        );
        assertEq(progressAfterPartialStake.stakeRemaining, 60 * DECIMALS, "stale stake remaining seeded");
        assertEq(vault.bufferedAssets(), 60 * DECIMALS, "buffer left after partial stake");

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);
        uint256 pendingBeforeResume = vault.pendingWithdrawalAssets();
        uint256 safeStakeAfterRequest = vault.bufferedAssets() - pendingBeforeResume;

        assertGt(request.assetsExpected, 0, "withdrawal request should need buffer");
        assertLt(safeStakeAfterRequest, progressAfterPartialStake.stakeRemaining, "fresh safe surplus should be lower");

        stakingManager.setStakeReturnAmount(safeStakeAfterRequest);

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.stake, (safeStakeAfterRequest)));

        vm.prank(operator);
        (,, uint256 stakedAmount,) = core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfterResume = core.rebalanceProgress();
        assertEq(stakedAmount, safeStakeAfterRequest, "resume stakes only fresh safe surplus");
        assertEq(uint256(progressAfterResume.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completes");
        assertEq(progressAfterResume.stakeRemaining, 0, "stake remaining clears");
        assertGe(vault.bufferedAssets(), pendingBeforeResume, "buffer still covers pending withdrawals");
    }

    function test_Rebalance_FinalizeWithdrawals_DoesNotFinalizePostSnapshotRequest() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 withdrawalShares = 10 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 firstRequestId = _requestWithdrawal(alice, withdrawalShares);

        uint32 defaultThreshold = core.rebalanceGasThreshold();
        _forceRebalanceGasThreshold(type(uint32).max);

        vm.prank(operator);
        core.rebalance();

        IOllaCore.RebalanceProgress memory progressAfterPark = core.rebalanceProgress();
        assertEq(
            uint256(progressAfterPark.step),
            uint256(IOllaCore.RebalanceStep.FinalizeWithdrawals),
            "rebalance should park before finalization"
        );

        uint256 secondRequestId = _requestWithdrawal(alice, withdrawalShares);

        _forceRebalanceGasThreshold(defaultThreshold);
        stakingManager.setStakeReturnAmount(0);

        vm.prank(operator);
        core.rebalance();

        IOllaVault.WithdrawalRequest memory firstRequest = vault.getWithdrawalRequest(firstRequestId);
        IOllaVault.WithdrawalRequest memory secondRequest = vault.getWithdrawalRequest(secondRequestId);

        assertTrue(firstRequest.finalized, "snapshot request should finalize");
        assertFalse(secondRequest.finalized, "post-snapshot request should remain pending");
    }

    /*//////////////////////////////////////////////////////////////
                    REWARDS VAULT SWAP (C3)
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_StakeSurplus_EmitsAfterFinalize() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 withdrawalShares = 20 * DECIMALS;
        uint256 targetBufferedAssets = 10 * DECIMALS;
        uint256 actualStaked = 64 * DECIMALS;

        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(targetBufferedAssets);

        uint256 requestId = _requestWithdrawal(alice, withdrawalShares);
        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setStakeReturnAmount(actualStaked);

        uint256 bufferedBefore = vault.bufferedAssets();
        uint256 bufferAfterFinalize = bufferedBefore - request.assetsExpected;
        uint256 stakeable = bufferAfterFinalize - targetBufferedAssets;
        uint256 expectedBufferAfter = bufferAfterFinalize - actualStaked;

        vm.expectCall(address(stakingManager), abi.encodeCall(stakingManager.stake, (stakeable)));

        vm.recordLogs();

        vm.prank(operator);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = core.rebalance();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 finalizedSelector = keccak256("WithdrawalFinalized(uint256,uint256)");
        bytes32 rebalancedSelector = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
        uint256 finalizedIndex = type(uint256).max;
        uint256 rebalancedIndex = type(uint256).max;

        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == finalizedSelector) {
                finalizedIndex = i;
            }
            if (entries[i].topics[0] == rebalancedSelector) {
                rebalancedIndex = i;
            }
        }

        assertTrue(finalizedIndex < rebalancedIndex, "finalize emits before rebalance");
        assertEq(stakedAmount, actualStaked, "staked amount uses staking manager return");
        assertEq(resultingBuffer, expectedBufferAfter, "resulting buffer accounts for stake");
    }

    /*//////////////////////////////////////////////////////////////
                    GAS EXHAUSTION: InitiateUnstake
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_ReturnsPartialProgress_WhenGasStopsAtInitiateUnstake() external {
        uint256 depositAmount = 100 * DECIMALS;

        _performDeposit(alice, depositAmount);

        // Create many small withdrawal requests so _finalizeWithdrawals consumes gas
        uint256 numRequests = 50;
        for (uint256 i = 0; i < numRequests; i++) {
            _requestWithdrawal(alice, 1 * DECIMALS);
        }

        // Target much higher than current buffer so unstakeRemaining > 0 after finalization
        vm.prank(governance);
        core.setTargetBufferedAssets(200 * DECIMALS);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;

        // Search for gas level that stops exactly at InitiateUnstake
        for (uint256 gasLimit = 200_000; gasLimit <= 2_000_000; gasLimit += 5_000) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success, bytes memory data) = address(core).call{ gas: gasLimit }(abi.encodeCall(core.rebalance, ()));
            if (!success) {
                continue;
            }

            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.InitiateUnstake) {
                (, uint256 loopFinalizedAmount, uint256 loopStakedAmount,) =
                    abi.decode(data, (uint256, uint256, uint256, uint256));
                if (loopStakedAmount == 0) {
                    selectedGas = gasLimit;
                    break;
                }
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for initiate-unstake stop");

        vm.revertToState(snapshotId);
        vm.prank(operator);
        (,, uint256 stakedAmount,) = core.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.InitiateUnstake),
            "rebalance should stop at initiate unstake"
        );
        assertEq(stakedAmount, 0, "staked amount should be zero on partial progress");
    }

    /*//////////////////////////////////////////////////////////////
                    GAS EXHAUSTION: StakeSurplus
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_ReturnsPartialProgress_WhenGasStopsAtStakeSurplus() external {
        uint256 depositAmount = 100 * DECIMALS;

        _performDeposit(alice, depositAmount);

        // Create many small withdrawal requests so _finalizeWithdrawals consumes gas
        // before reaching StakeSurplus
        uint256 numRequests = 20;
        for (uint256 i = 0; i < numRequests; i++) {
            _requestWithdrawal(alice, 1 * DECIMALS);
        }

        // Target is low so buffer > required: stakeRemaining will be > 0
        vm.prank(governance);
        core.setTargetBufferedAssets(10 * DECIMALS);

        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        stakingManager.setPendingUnstakes(0);

        uint256 snapshotId = vm.snapshotState();
        uint256 selectedGas;

        // Search for gas level that stops exactly at StakeSurplus
        for (uint256 gasLimit = 200_000; gasLimit <= 2_000_000; gasLimit += 5_000) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success, bytes memory data) = address(core).call{ gas: gasLimit }(abi.encodeCall(core.rebalance, ()));
            if (!success) {
                continue;
            }

            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.StakeSurplus) {
                (,, uint256 loopStakedAmount,) = abi.decode(data, (uint256, uint256, uint256, uint256));
                if (loopStakedAmount == 0) {
                    selectedGas = gasLimit;
                    break;
                }
            }
        }

        assertGt(selectedGas, 0, "should find gas stipend for stake-surplus stop");

        vm.revertToState(snapshotId);
        vm.prank(operator);
        (,, uint256 stakedAmount,) = core.rebalance{ gas: selectedGas }();

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        assertEq(
            uint256(progressAfter.step),
            uint256(IOllaCore.RebalanceStep.StakeSurplus),
            "rebalance should stop at stake surplus"
        );
        assertEq(stakedAmount, 0, "staked amount should be zero on partial progress");
    }
}

contract OllaCoreRebalanceReentrancyTest is Test {
    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MaliciousReentrantStakingManager internal stakingManager;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;

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

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MaliciousReentrantStakingManager();
        operator = makeAddr("operator");
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setProviderRewardsRecipient(makeAddr("providerRewardsRecipient"));
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_RevertsOnReentrantGetUnstakedFunds() external {
        stakingManager.setReentry(core, MaliciousReentrantStakingManager.ReentryAction.Rebalance);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(operator);
        core.rebalance();
    }
}

contract RevertingSafetyModule is ISafetyModule {
    error AccountingStale();

    address public immutable CORE_ADDRESS;
    address public immutable VAULT_ADDRESS;
    bool internal stale;

    constructor(address coreAddress, address vaultAddress) {
        CORE_ADDRESS = coreAddress;
        VAULT_ADDRESS = vaultAddress;
    }

    function setStale(bool value) external {
        stale = value;
    }

    function pause() external override { }

    function unpause() external override { }

    function isPaused() external pure override returns (bool) {
        return false;
    }

    function isDepositPaused() external pure override returns (bool) {
        return false;
    }

    function CORE() external view override returns (address) {
        return CORE_ADDRESS;
    }

    function VAULT() external view override returns (address) {
        return VAULT_ADDRESS;
    }

    function checkRateDrop(uint256, uint256) external pure override { }

    function checkQueueRatio(uint256, uint256) external pure override { }

    function checkAccountingLiveness() external view override {
        if (stale) {
            revert AccountingStale();
        }
    }

    function setDepositCap(uint256) external pure override { }

    function setWithdrawalMinimum(uint256) external pure override { }

    function setMinRateDropBps(uint256) external pure override { }

    function setRateHighWaterMark(uint256) external pure override { }

    function setMaxQueueRatioBps(uint256) external pure override { }

    function setMaxAccountingDelay(uint256) external pure override { }

    function setLatestAccountingTimestamp(uint256) external pure override { }

    function checkDepositAllowed(uint256, uint256) external pure override returns (bool allowed) {
        return allowed;
    }

    function checkWithdrawalMinimum(uint256) external pure override { }

    function depositCap() external pure override returns (uint256) {
        return type(uint256).max;
    }
}

contract OllaCoreRebalanceAccountingLivenessTest is Test {
    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    RevertingSafetyModule internal safetyModule;
    address internal operator;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        operator = makeAddr("operator");
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new RevertingSafetyModule(address(core), address(vault));

        stakingManager.setProviderRewardsRecipient(makeAddr("providerRewardsRecipient"));
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();
    }

    function test_Rebalance_RevertsWhen_AccountingStale() external {
        safetyModule.setStale(true);

        vm.prank(operator);
        vm.expectRevert(RevertingSafetyModule.AccountingStale.selector);
        core.rebalance();
    }
}

/*//////////////////////////////////////////////////////////////
                    REWARDS LIQUIDITY TESTS
//////////////////////////////////////////////////////////////*/

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";

/// @notice Staking manager that reverts on unstake when amount exceeds staked principal.
/// @dev Used to test that rebalance correctly accounts for rewards vault liquidity.
contract UnstakeRevertingStakingManager is IStakingManager {
    using SafeERC20 for IERC20;
    IERC20 public immutable STAKING_ASSET;

    uint256 public staked;
    uint256 public pending;
    uint256 public claimable;
    uint256 public slashing;
    bool public _exitableUnstakes;
    address public rewardsRecipient;
    ProviderConfig internal _providerConfig;

    constructor(IERC20 stakingAsset_) {
        STAKING_ASSET = stakingAsset_;
    }

    function setClaimableRewards(uint256 value) external {
        claimable = value;
    }

    function setSlashingDelta(uint256 value) external {
        slashing = value;
    }

    function setPendingUnstakes(uint256 value) external {
        pending = value;
    }

    function setWithdrawableUnstakes(uint256 value) external {
        _exitableUnstakes = value != 0;
    }

    function setRewardsRecipient(address recipient) external {
        rewardsRecipient = recipient;
    }

    function setProviderConfig(address, address rewardsRecipient_) external {
        _providerConfig = ProviderConfig({ rewardsRecipient: rewardsRecipient_ });
    }

    function initialize(IERC20, address, address, address, address, address) external pure override { }

    function setGasThreshold(uint256) external override { }

    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        STAKING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        staked += amount;
        return amount;
    }

    function unstake(uint256 amount) external override returns (uint256 unstakedAmount) {
        if (amount > staked) {
            revert StakingManager__InsufficientStake();
        }
        staked -= amount;
        return amount;
    }

    function refreshAttesterState(address[] calldata) external override { }

    function purgeFailedQueueEntry(address) external override { }

    function getUnstakedFunds() external pure override returns (uint256 received, uint256 exitAmount) {
        return (0, 0);
    }

    function harvestRewards() external override returns (uint256 harvested) {
        harvested = claimable;
        if (harvested > 0 && rewardsRecipient != address(0)) {
            MockAztec(address(STAKING_ASSET)).mint(rewardsRecipient, harvested);
            claimable = 0;
        }
        return harvested;
    }

    function getSlashingDelta() external view override returns (uint256 slashingDelta) {
        return slashing;
    }

    function getClaimableRewards() external view override returns (uint256 claimableRewards) {
        return claimable;
    }

    function totalStaked() external view override returns (uint256 stakedTotal) {
        return staked;
    }

    function getStakingState() external view override returns (StakingState memory state) {
        return StakingState({ slashingDelta: slashing, stakedAmount: staked, pendingUnstakeAmount: pending });
    }

    function pendingUnstakes() external view override returns (uint256 pendingUnstakeAmount) {
        return pending;
    }

    function hasFinalizedUnstakes() external view override returns (bool) {
        return _exitableUnstakes;
    }

    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _providerConfig;
    }

    function getActivatedAttesterCount() external pure override returns (uint256) {
        return 0;
    }

    function getPendingUnstakeCount() external pure override returns (uint256) {
        return 0;
    }

    function isUnstakePending(address) external pure override returns (bool) {
        return false;
    }

    function core() external pure override returns (address) {
        return address(0);
    }

    function canStake(uint256) external pure override returns (bool) {
        return true;
    }

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }
}

contract OllaCoreRebalanceRewardsLiquidityTest is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    UnstakeRevertingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    address internal governance;
    address internal alice;
    address internal operator;

    function setUp() external {
        asset = new MockAztec(address(this));
        stakingManager = new UnstakeRevertingStakingManager(asset);

        governance = address(new MockOllaGovernance());
        alice = makeAddr("alice");
        operator = makeAddr("operator");

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setProviderConfig(makeAddr("providerAdmin"), makeAddr("providerRewardsRecipient"));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        vm.warp(block.timestamp + 1 hours);
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    function test_Rebalance_HandlesWithdrawalsBackedByRewardsAccumulatorLiquidity() external {
        uint256 principal = 200_000 * DECIMALS;
        _performDeposit(alice, principal);

        // Stake everything so buffered liquidity is zero.
        vm.prank(operator);
        core.rebalance();
        assertEq(vault.bufferedAssets(), 0, "buffer should be zero after stake");

        // Simulate rewards sitting in the rewards vault (counted in totalAssets via accounting).
        uint256 rewards = 69 * DECIMALS;
        asset.mint(address(rewardsAccumulator), rewards);

        // Advance past rebalance cooldown after first cycle completion
        uint256 t1 = block.timestamp + 1 hours;
        vm.warp(t1);

        // Persist rewardsAccumulatorBalance into accounting so exchangeRate/totalAssets includes it.
        vm.prank(operator);
        core.updateAccounting();

        // Request redeem of all shares; assetsExpected includes rewards.
        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        // Advance past rebalance cooldown after updateAccounting updated _latestReport.timestamp
        vm.warp(t1 + 1 hours);

        // Rebalance should use rewards-accumulator funds as liquidity and avoid over-unstaking.
        // Previously this would revert with StakingManager__InsufficientStake because
        // _initiateUnstake sized against bufferedAssets only.
        vm.prank(operator);
        core.rebalance();
    }

    function test_Rebalance_HandlesWithdrawalsBackedByClaimableRewards() external {
        uint256 principal = 200_000 * DECIMALS;
        _performDeposit(alice, principal);

        vm.prank(operator);
        core.rebalance();
        assertEq(vault.bufferedAssets(), 0, "buffer should be zero after stake");

        // Set rewards recipient so harvest actually transfers tokens to rewards vault
        stakingManager.setRewardsRecipient(address(rewardsAccumulator));

        // Advance past rebalance cooldown after first cycle completion
        uint256 t1 = block.timestamp + 1 hours;
        vm.warp(t1);

        // Simulate claimable rewards being included in totalAssets.
        uint256 claimableRewards = 69 * DECIMALS;
        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        core.updateAccounting();

        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        // Advance past rebalance cooldown after updateAccounting updated _latestReport.timestamp
        vm.warp(t1 + 1 hours);

        // Rebalance should not over-request unstake when withdrawals include claimable rewards.
        // The harvest step pulls the rewards into the buffer before unstake sizing.
        vm.prank(operator);
        core.rebalance();
    }
}
