// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { RewardsAccumulator } from "src/core/RewardsAccumulator.sol";
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

/// @title RefreshAttesterStateIntegration
/// @notice Integration tests for deposit -> rebalance -> staked principal consistency.
contract RefreshAttesterStateIntegration is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    RewardsAccumulator internal rewardsAccumulator;
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

        // Deploy RewardsAccumulator
        RewardsAccumulator rewardsImplementation = new RewardsAccumulator();
        ERC1967Proxy rewardsProxy = new ERC1967Proxy(address(rewardsImplementation), "");
        rewardsAccumulator = RewardsAccumulator(address(rewardsProxy));
        rewardsAccumulator.initialize(IERC20(asset), address(core), governance);

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
            address(rewardsAccumulator),
            address(core),
            address(stakingProviderRegistry),
            governance
        );

        // Deploy SafetyModule
        safetyModule = new SafetyModule(
            governance, governance, address(core), address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days
        );

        // Initialize OllaCore
        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        // Initialize OllaVault
        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        operator = makeAddr("operator");
        alice = makeAddr("alice");

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
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

    function _completeRebalance() internal {
        for (uint256 i; i < 10; ++i) {
            if (core.rebalanceProgress().step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }
    }

    function _allAttesterAddresses() internal view returns (address[] memory) {
        address[] memory addrs = new address[](_keyOffset);
        for (uint256 i; i < _keyOffset; ++i) {
            addrs[i] = address(uint160(i + 1));
        }
        return addrs;
    }

    function _refreshAttesters() internal {
        stakingManager.refreshAttesterState(_allAttesterAddresses());
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Core test: deposit -> rebalance -> totalStaked > 0
    function test_computeAttesterState_reflectsStakedAmount() external {
        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(5);

        uint256 depositAmount = 200_006 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        // Promote Queued -> Active
        _refreshAttesters();

        uint256 attesterCount = stakingManager.getActivatedAttesterCount();
        assertGt(attesterCount, 0, "Should have at least one attester registered");

        uint256 totalStaked = stakingManager.totalStaked();
        assertGt(totalStaked, 0, "totalStaked must be > 0 after staking");
        assertEq(totalStaked, activationThreshold, "totalStaked should equal activation threshold (1 attester)");
    }

    /// @notice Tests that the full flow (deposit -> rebalance) results in
    ///         OllaCore.stakedPrincipal reflecting the staked amount.
    function test_fullFlow_stakedPrincipalUpdatedAfterRebalance() external {
        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(3);

        uint256 depositAmount = 400_000 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete"
        );

        uint256 totalStaked = stakingManager.totalStaked();
        assertEq(totalStaked, activationThreshold * 2, "totalStaked should be 2x activation threshold");

        IOllaCore.AccountingState memory statePostRebalance = core.accountingState();
        assertEq(
            statePostRebalance.stakedPrincipal,
            activationThreshold * 2,
            "OllaCore stakedPrincipal must match totalStaked after rebalance"
        );
    }

    /// @notice Tests multi-attester scenario to ensure the loop processes all attesters.
    function test_computeAttesterState_multipleAttesters() external {
        uint256 activationThreshold = 50 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 numAttesters = 5;
        _addKeys(numAttesters);

        uint256 depositAmount = activationThreshold * numAttesters;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        // Promote Queued -> Active
        _refreshAttesters();

        uint256 activatedCount = stakingManager.getActivatedAttesterCount();
        assertEq(activatedCount, numAttesters, "Should have all attesters registered");

        uint256 totalStaked = stakingManager.totalStaked();
        assertEq(totalStaked, activationThreshold * numAttesters, "totalStaked should be sum of all attester stakes");
    }

    /// @notice Completes a full rebalance cycle, then calls updateAccounting
    ///         to verify the steady-state refresh path still works.
    function test_standaloneUpdateAccounting_afterRebalance() external {
        uint256 activationThreshold = 100 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(2);

        uint256 depositAmount = activationThreshold * 2;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete"
        );

        IOllaCore.AccountingState memory stateAfterRebalance = core.accountingState();
        assertEq(
            stateAfterRebalance.stakedPrincipal, activationThreshold * 2, "stakedPrincipal should match after rebalance"
        );

        vm.warp(block.timestamp + 1 hours);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.AccountingState memory stateAfterAccounting = core.accountingState();
        assertEq(
            stateAfterAccounting.stakedPrincipal,
            activationThreshold * 2,
            "stakedPrincipal should be correct after standalone updateAccounting"
        );
    }

    /// @notice Verifies that totalAssets (and exchange rate) never drops during the
    ///         unstake lifecycle: rebalance(InitiateUnstake) -> refreshAttesterState -> accounting -> rebalance(PullUnstaked).
    ///         Regression test for a bug where _processUnstakeAttester eagerly reduced stakedAmount
    ///         but the pending exit wasn't reflected in totalAssets until PullUnstaked.
    function test_totalAssets_neverDrops_duringUnstakeLifecycle() external {
        uint256 activationThreshold = 200_000 * DECIMALS;
        mockRollup.setActivationThreshold(activationThreshold);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        _addKeys(2);

        // Deposit enough to create 2 attesters
        uint256 depositAmount = activationThreshold * 2;
        _performDeposit(alice, depositAmount);

        // Stake via rebalance
        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        // Promote Queued -> Active
        _refreshAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), 2, "should have 2 attesters");

        // The completed rebalance already ran _updateAccountingInternal.
        // Record baseline.
        uint256 totalAssetsBefore = core.totalAssets();
        uint256 exchangeRateBefore = core.exchangeRate();
        assertEq(totalAssetsBefore, depositAmount, "totalAssets should equal deposit");

        // --- Phase 1: Rebalance that initiates unstake ---
        // Raise targetBufferedAssets to force unstaking of one attester
        vm.prank(governance);
        core.setTargetBufferedAssets(activationThreshold);

        uint256 t1 = block.timestamp + 2 hours;
        vm.warp(t1);
        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        // totalAssets should NOT have dropped after unstake + accounting
        uint256 totalAssetsAfterUnstake = core.totalAssets();
        assertGe(totalAssetsAfterUnstake, totalAssetsBefore, "totalAssets must not drop after unstake rebalance");

        uint256 exchangeRateAfterUnstake = core.exchangeRate();
        assertGe(exchangeRateAfterUnstake, exchangeRateBefore, "exchange rate must not drop after unstake rebalance");

        // --- Phase 2: refreshAttesterState finalizes exits ---
        address[] memory attesters = new address[](2);
        attesters[0] = address(uint160(1));
        attesters[1] = address(uint160(2));
        stakingManager.refreshAttesterState(attesters);

        uint256 totalAssetsAfterRefresh = core.totalAssets();
        assertGe(totalAssetsAfterRefresh, totalAssetsBefore, "totalAssets must not drop after refreshAttesterState");

        // --- Phase 3: Standalone accounting after finalization ---
        uint256 t2 = t1 + 2 hours;
        vm.warp(t2);
        core.updateAccounting();

        uint256 totalAssetsAfterAccounting = core.totalAssets();
        assertGe(
            totalAssetsAfterAccounting, totalAssetsBefore, "totalAssets must not drop after accounting post-finalize"
        );

        uint256 exchangeRateAfterAccounting = core.exchangeRate();
        assertGe(
            exchangeRateAfterAccounting,
            exchangeRateBefore,
            "exchange rate must not drop after accounting post-finalize"
        );

        // --- Phase 4: Next rebalance PullUnstaked recovers funds to buffer ---
        uint256 t3 = t2 + 2 hours;
        vm.warp(t3);
        vm.prank(operator);
        core.rebalance();
        _completeRebalance();

        uint256 totalAssetsAfterPull = core.totalAssets();
        assertGe(totalAssetsAfterPull, totalAssetsBefore, "totalAssets must not drop after PullUnstaked");

        uint256 exchangeRateAfterPull = core.exchangeRate();
        assertGe(exchangeRateAfterPull, exchangeRateBefore, "exchange rate must be monotonically non-decreasing");
    }
}
