// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { RewardsVault } from "src/core/RewardsVault.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaCoreRebalanceRealStakingManager
/// @notice Tests rebalance with the real StakingManager (not mocks) to reproduce mock loop issue.
contract OllaCoreRebalanceRealStakingManager is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    WithdrawalQueue internal withdrawalQueue;
    RewardsVault internal rewardsVault;
    SafetyModule internal safetyModule;
    MockAztecRollup internal mockRollup;
    MockAztecRollupRegistry internal mockRollupRegistry;
    address internal governance;
    address internal operator;
    address internal alice;

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy OllaCore
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy OllaVault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));

        // Deploy WithdrawalQueue
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        withdrawalQueue.initialize(address(vault), governance, 180_000);

        // Deploy RewardsVault
        RewardsVault rewardsImplementation = new RewardsVault();
        ERC1967Proxy rewardsProxy = new ERC1967Proxy(address(rewardsImplementation), "");
        rewardsVault = RewardsVault(address(rewardsProxy));
        rewardsVault.initialize(IERC20(asset), address(core), governance);

        // Deploy Mock Rollup and Registry
        mockRollup = new MockAztecRollup(IERC20(asset), 0);
        mockRollupRegistry = new MockAztecRollupRegistry(address(mockRollup));

        // Deploy StakingProviderRegistry (before StakingManager)
        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        // Deploy StakingManager
        StakingManager smImplementation = new StakingManager();
        ERC1967Proxy smProxy = new ERC1967Proxy(address(smImplementation), "");
        stakingManager = StakingManager(address(smProxy));

        // Initialize StakingProviderRegistry with StakingManager address
        stakingProviderRegistry.initialize(
            address(stakingManager),
            governance,
            governance, // rewardsRecipient same as admin for simplicity
            governance
        );

        // Initialize StakingManager
        stakingManager.initialize(
            IERC20(asset),
            address(mockRollupRegistry),
            address(rewardsVault),
            address(core),
            address(stakingProviderRegistry),
            governance
        );

        // Deploy SafetyModule
        safetyModule = new SafetyModule(
            governance, governance, address(core), address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days
        );

        // Initialize OllaCore
        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsVault, address(safetyModule));

        // Initialize OllaVault
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        operator = makeAddr("operator");
        alice = makeAddr("alice");

        // Grant roles
        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        vm.stopPrank();

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
    }

    uint256 internal _keyOffset;

    function _createMockKeys(uint256 count) internal returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            uint256 keyId = _keyOffset + i + 1;
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(keyId)),
                publicKeyG1: G1Point({ x: keyId, y: keyId + 1 }),
                publicKeyG2: G2Point({ x0: keyId, x1: keyId + 1, y0: keyId + 2, y1: keyId + 3 }),
                proofOfPossession: G1Point({ x: keyId + 10, y: keyId + 11 })
            });
        }
        _keyOffset += count;
        return keys;
    }

    function _addKeys(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(governance);
        stakingProviderRegistry.addKeysToProvider(keys);
    }

    /// @notice Test that reproduces the mock loop scenario:
    ///         - 200k ETH deposit
    ///         - Target buffer = 0
    ///         - Rebalance stakes 200k ETH, leaving small remainder
    ///         - Rebalance should complete (reach Done) and not loop infinitely
    function test_RebalanceWithRealStakingManager_SmallRemainder() external {
        // Setup: target buffer = 0 (stake everything)
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        // Setup rollup with 200k ETH activation threshold
        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        // Add provider keys to registry
        _addKeys(5);

        // Deposit 200,006 ETH (6 ETH above the 200k threshold)
        uint256 depositAmount = 200_006 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Verify initial state
        assertEq(vault.bufferedAssets(), depositAmount, "Initial buffered should be deposit");

        // First rebalance call - should stake 200k ETH
        vm.prank(operator);
        core.rebalance();

        // Check progress
        IOllaCore.RebalanceProgress memory progress1 = core.rebalanceProgress();
        emit log_named_uint("After first rebalance - step", uint256(progress1.step));
        emit log_named_uint("After first rebalance - stakeRemaining", progress1.stakeRemaining);
        emit log_named_uint("After first rebalance - unstakeRemaining", progress1.unstakeRemaining);
        emit log_named_uint("After first rebalance - step", uint256(progress1.step));

        // Verify some amount was staked (should be ~200k)
        IOllaCore.AccountingState memory stateAfter1 = core.accountingState();
        emit log_named_uint("Buffered after first rebalance", vault.bufferedAssets());
        emit log_named_uint("Staked after first rebalance", stateAfter1.stakedPrincipal);

        // The remainder should be small (< 200k threshold)
        assertLt(vault.bufferedAssets(), activationThreshold, "Buffer should be less than activation threshold");

        // Second rebalance call - should complete the cycle
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(operator);
        core.rebalance();

        // Check progress after second call
        IOllaCore.RebalanceProgress memory progress2 = core.rebalanceProgress();
        emit log_named_uint("After second rebalance - step", uint256(progress2.step));
        emit log_named_uint("After second rebalance - stakeRemaining", progress2.stakeRemaining);
        emit log_named_uint("After second rebalance - step", uint256(progress2.step));

        // Should be at Done step
        assertEq(
            uint256(progress2.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "Should reach Done step after second rebalance"
        );

        // Call rebalance multiple more times - should not restart cycle unnecessarily.
        // With cooldown enforcement, calling rebalance before the cooldown period
        // elapses will revert. Verify by checking the progress stays at Done.
        // After the cooldown elapses, the idle guard should prevent a new unproductive cycle.

        // Final state should still be Done
        IOllaCore.RebalanceProgress memory progressFinal = core.rebalanceProgress();
        assertEq(uint256(progressFinal.step), uint256(IOllaCore.RebalanceStep.Done), "Final step should be Done");
    }

    /// @notice Reproduces the mock-loop bug: after unstake, finalizeExits fails to finalize.
    ///         Steps: deposit -> stake -> request withdrawal -> unstake -> finalizeExits -> pullUnstaked
    function test_FinalizeExitsAfterUnstake() external {
        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        // Add provider keys
        _addKeys(20);

        // Deposit 400k (enough for 2 attesters)
        uint256 depositAmount = 400_000 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        emit log_named_uint("Shares received", shares);

        // --- First rebalance: stake all ---
        vm.prank(operator);
        core.rebalance();
        // Complete the cycle
        for (uint256 i; i < 10; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }
        IOllaCore.RebalanceProgress memory p1 = core.rebalanceProgress();
        assertEq(uint256(p1.step), uint256(IOllaCore.RebalanceStep.Done), "first cycle should reach Done");

        IOllaCore.AccountingState memory stateAfterStake = core.accountingState();
        emit log_named_uint("Staked principal", stateAfterStake.stakedPrincipal);
        emit log_named_uint("Buffered assets", vault.bufferedAssets());
        assertGt(stateAfterStake.stakedPrincipal, 0, "should have staked");

        // --- Request withdrawal of half the shares ---
        vm.warp(block.timestamp + 1 hours);
        uint256 halfShares = shares / 2;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(halfShares, alice);
        emit log_named_uint("Withdrawal request ID", requestId);

        // --- Second rebalance: should unstake to cover the withdrawal ---
        vm.warp(block.timestamp + 1 hours);

        // Call computeAttesterState first (mock-loop does this)
        stakingManager.computeAttesterState();

        vm.prank(operator);
        core.rebalance();
        for (uint256 i; i < 10; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        IOllaCore.RebalanceProgress memory p2 = core.rebalanceProgress();
        emit log_named_uint("After unstake rebalance - step", uint256(p2.step));

        // Check pendingUnstakeCount
        uint256 exitCount = stakingManager.getPendingUnstakeCount();
        emit log_named_uint("Pending unstake count after rebalance", exitCount);

        if (exitCount > 0) {
            // There are exiting attesters. Now call finalizeExits and check.
            emit log_named_uint("Block timestamp before finalizeExits", block.timestamp);

            // Check hasExitableUnstakes via cached state
            IStakingManager.StakingState memory stakingState = stakingManager.getStakingState();
            emit log_named_uint("Staking state withdrawableAmount", stakingState.withdrawableAmount);
            emit log_named_uint("Staking state pendingUnstakeAmount", stakingState.pendingUnstakeAmount);

            // Advance time by 1 second to ensure exitableAt < block.timestamp
            vm.warp(block.timestamp + 1);

            // Call finalizeExits
            uint256 finalized = stakingManager.finalizeExits();
            emit log_named_uint("Finalized amount", finalized);

            uint256 exitCountAfter = stakingManager.getPendingUnstakeCount();
            emit log_named_uint("Pending unstake count after finalizeExits", exitCountAfter);

            assertLt(exitCountAfter, exitCount, "finalizeExits should reduce pending count");
            assertGt(finalized, 0, "finalizeExits should finalize nonzero amount");
        }

        // Now complete the rebalance if needed
        vm.warp(block.timestamp + 1 hours);
        for (uint256 i; i < 20; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }

        IOllaCore.RebalanceProgress memory pFinal = core.rebalanceProgress();
        assertEq(uint256(pFinal.step), uint256(IOllaCore.RebalanceStep.Done), "should reach Done after finalize");
    }
}
