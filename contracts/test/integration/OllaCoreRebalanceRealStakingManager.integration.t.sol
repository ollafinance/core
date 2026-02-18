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

/// @title OllaCoreRebalanceRealStakingManager
/// @notice Tests rebalance with the real StakingManager (not mocks) to reproduce mock loop issue.
contract OllaCoreRebalanceRealStakingManager is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal vault;
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
        vault = OllaCore(address(coreProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));

        // Deploy WithdrawalQueue
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        withdrawalQueue.initialize(address(vault), governance);

        // Deploy RewardsVault
        RewardsVault rewardsImplementation = new RewardsVault();
        ERC1967Proxy rewardsProxy = new ERC1967Proxy(address(rewardsImplementation), "");
        rewardsVault = RewardsVault(address(rewardsProxy));
        rewardsVault.initialize(IERC20(asset), address(vault), governance);

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
            address(vault),
            address(stakingProviderRegistry),
            governance
        );

        // Deploy SafetyModule
        safetyModule =
            new SafetyModule(governance, governance, address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days);

        // Initialize OllaCore
        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        operator = makeAddr("operator");
        alice = makeAddr("alice");

        // Grant roles
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
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
        vault.setTargetBufferedAssets(0);

        // Setup rollup with 200k ETH activation threshold
        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        // Add provider keys to registry
        _addKeys(5);

        // Deposit 200,006 ETH (6 ETH above the 200k threshold)
        uint256 depositAmount = 200_006 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Verify initial state
        IOllaCore.AccountingState memory stateBefore = vault.accountingState();
        assertEq(stateBefore.bufferedAssets, depositAmount, "Initial buffered should be deposit");

        // First rebalance call - should stake 200k ETH
        vm.prank(operator);
        vault.rebalance();

        // Check progress
        IOllaCore.RebalanceProgress memory progress1 = vault.rebalanceProgress();
        emit log_named_uint("After first rebalance - step", uint256(progress1.step));
        emit log_named_uint("After first rebalance - stakeRemaining", progress1.stakeRemaining);
        emit log_named_uint("After first rebalance - unstakeRemaining", progress1.unstakeRemaining);
        emit log_named_uint("After first rebalance - isPaused", vault.isRebalancePaused() ? 1 : 0);

        // Verify some amount was staked (should be ~200k)
        IOllaCore.AccountingState memory stateAfter1 = vault.accountingState();
        emit log_named_uint("Buffered after first rebalance", stateAfter1.bufferedAssets);
        emit log_named_uint("Staked after first rebalance", stateAfter1.stakedPrincipal);

        // The remainder should be small (< 200k threshold)
        assertLt(stateAfter1.bufferedAssets, activationThreshold, "Buffer should be less than activation threshold");

        // Second rebalance call - should complete the cycle
        vm.prank(operator);
        vault.rebalance();

        // Check progress after second call
        IOllaCore.RebalanceProgress memory progress2 = vault.rebalanceProgress();
        emit log_named_uint("After second rebalance - step", uint256(progress2.step));
        emit log_named_uint("After second rebalance - stakeRemaining", progress2.stakeRemaining);
        emit log_named_uint("After second rebalance - isPaused", vault.isRebalancePaused() ? 1 : 0);

        // Should be at Done step
        assertEq(
            uint256(progress2.step),
            uint256(IOllaCore.RebalanceStep.Done),
            "Should reach Done step after second rebalance"
        );

        // Call rebalance multiple more times - should not restart cycle unnecessarily
        for (uint256 i = 0; i < 5; i++) {
            vm.recordLogs();
            vm.prank(operator);
            vault.rebalance();

            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 rebalancedSig = keccak256("Rebalanced(uint256,uint256,uint256,uint256)");
            uint256 rebalancedCount = 0;
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == rebalancedSig) {
                    rebalancedCount++;
                }
            }

            // After completion, subsequent calls should not emit Rebalanced (no new cycle)
            assertEq(rebalancedCount, 0, string.concat("Call ", vm.toString(i + 3), " should not start new cycle"));
        }

        // Final state should still be Done
        IOllaCore.RebalanceProgress memory progressFinal = vault.rebalanceProgress();
        assertEq(uint256(progressFinal.step), uint256(IOllaCore.RebalanceStep.Done), "Final step should be Done");
    }
}
