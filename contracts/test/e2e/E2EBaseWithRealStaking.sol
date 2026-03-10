// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { RewardsAccumulator } from "src/core/RewardsAccumulator.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { RolesLib } from "src/shared/RolesLib.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";

/// @title E2EBaseWithRealStaking
/// @notice Shared base for E2E tests that deploy real StakingManager + real RewardsAccumulator
///         instead of mocks, wired through OllaGovernance.
/// @dev Subclasses only need to override setUp(), call _deployFullStack(), then add keys / configure.
abstract contract E2EBaseWithRealStaking is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500; // 5%
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000; // 50/50
    uint256 internal constant BP_DIVISOR = 10_000;
    uint256 internal constant DEPOSIT_CAP = 10_000_000 * DECIMALS;

    /*//////////////////////////////////////////////////////////////
                             TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    // Real contracts
    OllaGovernance internal gov;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    WithdrawalQueue internal withdrawalQueue;
    SafetyModule internal safetyModule;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    RewardsAccumulator internal rewardsAccumulator;

    // Mock contracts
    MockAztec internal asset;
    MockAztecRollup internal mockRollup;
    MockAztecRollupRegistry internal mockRollupRegistry;

    // Actors
    address internal admin;
    address internal guardian;
    address internal operator;
    address internal alice;
    address internal bob;
    address internal treasury;
    address internal providerRewards;

    // Key offset tracker
    uint256 internal _keyOffset;

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys and wires the full real-staking stack. Call from setUp().
    function _deployFullStack() internal {
        _createActors();
        _deployAsset();
        _deployGovernance();
        _deployCoreAndVault();
        _deployStakingInfrastructure();
        _deploySafetyModule();
        _initializeCoreAndVault();
        _wireContracts();
        _unpause();

        // Advance past rebalance cooldown
        vm.warp(block.timestamp + 1 hours);

        // Reset MockAztecRollup.lastTick so that tick() only accrues rewards
        // from this point forward, not from the constructor timestamp.
        // Uses a burn address to discard any rewards accumulated during setUp warps.
        mockRollup.tick(address(0xdead));
    }

    function _createActors() internal {
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        treasury = makeAddr("treasury");
        providerRewards = makeAddr("providerRewards");
    }

    function _deployAsset() internal {
        asset = new MockAztec(address(this));
    }

    function _deployGovernance() internal {
        OllaGovernance govImpl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(OllaGovernance.initialize, (MIN_DELAY, proposers, executors, admin, treasury))
        );
        gov = OllaGovernance(payable(address(govProxy)));
    }

    function _deployCoreAndVault() internal {
        // OllaCore
        OllaCore coreImpl = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        core = OllaCore(address(coreProxy));

        // OllaVault
        OllaVault vaultImpl = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        vault = OllaVault(address(vaultProxy));

        // StAztec
        stAztec = new StAztec(address(vault));

        // WithdrawalQueue
        WithdrawalQueue queueImpl = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImpl), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));
        withdrawalQueue.initialize(address(vault), address(gov), 180_000);
    }

    function _deployStakingInfrastructure() internal {
        // RewardsAccumulator (real, behind proxy)
        RewardsAccumulator raImpl = new RewardsAccumulator();
        ERC1967Proxy raProxy = new ERC1967Proxy(address(raImpl), "");
        rewardsAccumulator = RewardsAccumulator(address(raProxy));
        rewardsAccumulator.initialize(IERC20(asset), address(core), address(gov));

        // MockAztecRollup + Registry
        mockRollup = new MockAztecRollup(IERC20(asset), 0);
        mockRollupRegistry = new MockAztecRollupRegistry(address(mockRollup));

        // StakingProviderRegistry (real, behind proxy)
        StakingProviderRegistry regImpl = new StakingProviderRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), "");
        stakingProviderRegistry = StakingProviderRegistry(address(regProxy));

        // StakingManager (real, behind proxy)
        StakingManager smImpl = new StakingManager();
        ERC1967Proxy smProxy = new ERC1967Proxy(address(smImpl), "");
        stakingManager = StakingManager(address(smProxy));

        // Initialize registry with StakingManager address
        stakingProviderRegistry.initialize(
            address(stakingManager),
            address(gov), // admin
            providerRewards, // rewardsRecipient
            address(gov) // defaultAdmin
        );

        // Initialize StakingManager
        stakingManager.initialize(
            IERC20(asset),
            address(mockRollupRegistry),
            address(rewardsAccumulator),
            address(core),
            address(stakingProviderRegistry),
            address(gov)
        );
    }

    function _deploySafetyModule() internal {
        safetyModule = new SafetyModule(
            address(gov), // admin
            address(gov), // guardian
            address(core),
            address(vault),
            DEPOSIT_CAP,
            500, // minRateDropBps = 5%
            6_000, // maxQueueRatioBps = 60%
            7 days // maxAccountingDelay
        );
    }

    function _initializeCoreAndVault() internal {
        core.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            address(gov),
            rewardsAccumulator,
            address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), address(gov));
    }

    function _wireContracts() internal {
        vm.prank(address(gov));
        core.setVault(address(vault));
        vm.prank(admin);
        gov.setCore(address(core));
    }

    function _unpause() internal {
        vm.prank(address(gov));
        core.unpause();
        vm.prank(address(gov));
        vault.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits assets into the vault for a given user.
    function _deposit(address depositor, uint256 assets) internal returns (uint256 shares) {
        asset.mint(depositor, assets);
        vm.prank(depositor);
        asset.approve(address(vault), assets);
        vm.prank(depositor);
        shares = vault.deposit(assets, depositor, 0);
    }

    /// @notice Requests async redemption for a given user.
    function _requestRedeem(address user, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(user);
        stAztec.approve(address(vault), shares);
        vm.prank(user);
        requestId = vault.requestRedeem(shares, user, user);
    }

    /// @notice Creates mock attester keys and adds them to the registry.
    function _addKeys(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(address(gov));
        stakingProviderRegistry.addKeysToProvider(keys);
    }

    /// @notice Creates mock attester keystores.
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

    /// @notice Returns all attester addresses created so far.
    function _allAttesterAddresses() internal view returns (address[] memory) {
        address[] memory addrs = new address[](_keyOffset);
        for (uint256 i; i < _keyOffset; ++i) {
            addrs[i] = address(uint160(i + 1));
        }
        return addrs;
    }

    /// @notice Runs rebalance to completion (up to maxIter calls).
    function _rebalanceToCompletion(uint256 maxIter) internal {
        for (uint256 i; i < maxIter; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) {
                // Start a new cycle if the previous completed
                vm.prank(operator);
                core.rebalance();
                // Check if it immediately completed (idle guard)
                p = core.rebalanceProgress();
                if (p.step == IOllaCore.RebalanceStep.Done) break;
            } else {
                vm.prank(operator);
                core.rebalance();
            }
        }
    }

    /// @notice Runs a single rebalance call.
    function _rebalance()
        internal
        returns (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer)
    {
        vm.prank(operator);
        return core.rebalance();
    }

    /// @notice Completes any in-progress rebalance cycle.
    function _completeRebalance() internal {
        for (uint256 i; i < 20; ++i) {
            IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
            if (p.step == IOllaCore.RebalanceStep.Done) break;
            vm.prank(operator);
            core.rebalance();
        }
    }

    /// @notice Schedules and executes a governance action via the timelock.
    /// @dev Warps forward to the timelock execution timestamp, then resets
    ///      MockAztecRollup.lastTick so that tick()-based reward accrual
    ///      does not silently include the governance delay period.
    function _scheduleAndExecute(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(admin);
        gov.schedule(target, 0, data, bytes32(0), salt, MIN_DELAY);
        bytes32 id = gov.hashOperation(target, 0, data, bytes32(0), salt);
        vm.warp(gov.getTimestamp(id));
        vm.prank(admin);
        gov.execute(target, 0, data, bytes32(0), salt);

        // Reset lastTick so tick() only counts time from after the governance warp.
        mockRollup.tick(address(0xdead));
    }

    /// @notice Warps past the rebalance cooldown.
    /// @dev Resets MockAztecRollup.lastTick so that tick()-based reward accrual
    ///      does not silently include the cooldown period.
    function _warpPastCooldown() internal {
        vm.warp(block.timestamp + 1 hours + 1);
        mockRollup.tick(address(0xdead));
    }

    /// @notice Calls refreshAttesterState for all known attesters.
    function _refreshAttesters() internal {
        stakingManager.refreshAttesterState(_allAttesterAddresses());
    }
}
