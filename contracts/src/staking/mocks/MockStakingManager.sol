// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";

// solhint-disable max-states-count
/// @title MockStakingManager
/// @notice Minimal staking manager mock for message routing tests.
/// @author Olla Core contributors
contract MockStakingManager is IStakingManager {
    /// @notice The core contract address.
    address public core;

    /// @notice The staking provider registry.
    IStakingProviderRegistry private _stakingProviderRegistry;

    /// @notice Last amount requested to stake.
    uint256 public lastStakeAmount;

    /// @notice Last amount requested to unstake.
    uint256 public lastUnstakeAmount;

    /// @notice Number of stake calls received.
    uint256 public stakeCalls;

    /// @notice Number of unstake calls received.
    uint256 public unstakeCalls;

    /// @notice Simulated staked amount for getStakingState.
    uint256 private _stakedAmount;

    /// @notice Simulated active attester count.
    uint256 public activatedAttesterCount;

    /// @notice Simulated exiting attester count.
    uint256 public pendingUnstakeCount;

    /// @notice Mock provider config.
    ProviderConfig private _providerConfig;

    /// @notice Cached slashing delta.
    uint256 private _slashingDelta;

    /// @notice Cached total staked principal.
    uint256 private _cachedTotalStaked;

    /// @notice Cached pending unstake amount.
    uint256 private _cachedPendingUnstakeAmount;

    /// @notice Cached withdrawable amount.
    uint256 private _cachedWithdrawableAmount;

    /// @notice Timestamp when slashing delta was last updated.
    uint256 private _slashingDeltaLastUpdated = 1;

    /// @notice Maximum allowed age for slashing delta freshness.
    uint256 private _slashingDeltaMaxAge = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice No-op initializer for interface compatibility.
    /// @param stakingAsset Unused.
    /// @param rollupRegistry Unused.
    /// @param rewardsVault Unused.
    /// @param core_ The core contract address.
    /// @param stakingProviderRegistry_ The staking provider registry address.
    /// @param defaultAdmin Unused.
    function initialize(
        IERC20 stakingAsset,
        address rollupRegistry,
        address rewardsVault,
        address core_,
        address stakingProviderRegistry_,
        address defaultAdmin
    ) external override {
        stakingAsset;
        rollupRegistry;
        rewardsVault;
        core = core_;
        _stakingProviderRegistry = IStakingProviderRegistry(stakingProviderRegistry_);
        defaultAdmin;
        return;
    }

    /// @notice Records a stake request.
    /// @param amount The amount to stake.
    /// @return stakedAmount The amount recorded as staked.
    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        lastStakeAmount = amount;
        _stakedAmount += amount;
        ++stakeCalls;
        return amount;
    }

    /// @notice Records an unstake request.
    /// @param amount The amount to unstake.
    /// @return unstakedAmount The amount initiated for unstake.
    function unstake(uint256 amount) external override returns (uint256 unstakedAmount) {
        lastUnstakeAmount = amount;
        unstakedAmount = amount;
        if (unstakedAmount > _stakedAmount) {
            unstakedAmount = _stakedAmount;
        }
        _stakedAmount -= unstakedAmount;
        if (activatedAttesterCount > 0) {
            --activatedAttesterCount;
            ++pendingUnstakeCount;
        }
        ++unstakeCalls;
        return unstakedAmount;
    }

    /// @inheritdoc IStakingManager
    function computeAttesterState() external override returns (uint256 slashingDelta, bool completed) {
        uint256 lastUpdated = _slashingDeltaLastUpdated;
        bool wasStale = _isSlashingDeltaStale();

        _cachedTotalStaked = _stakedAmount;
        _slashingDeltaLastUpdated = block.timestamp;
        emit AttesterStateUpdated(
            _slashingDelta, _cachedTotalStaked, _cachedPendingUnstakeAmount, _cachedWithdrawableAmount, block.timestamp
        );
        if (wasStale) {
            emit SlashingDeltaStale(lastUpdated, _slashingDeltaMaxAge);
        }

        return (_slashingDelta, true);
    }

    /// @inheritdoc IStakingManager
    function setSlashingDeltaMaxAge(uint256 maxAge) external override {
        if (maxAge == 0) {
            revert StakingManager__ZeroAmount();
        }
        uint256 oldMaxAge = _slashingDeltaMaxAge;
        _slashingDeltaMaxAge = maxAge;
        emit SlashingDeltaMaxAgeUpdated(oldMaxAge, maxAge);
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function stakingProviderRegistry() external view override returns (IStakingProviderRegistry) {
        return _stakingProviderRegistry;
    }

    /// @inheritdoc IStakingManager
    function getStakingState() external view override returns (StakingState memory) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_slashingDeltaLastUpdated, _slashingDeltaMaxAge);
        }
        return StakingState({
            stakedAmount: _cachedTotalStaked,
            pendingUnstakeAmount: _cachedPendingUnstakeAmount,
            withdrawableAmount: _cachedWithdrawableAmount
        });
    }

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256 stakedTotal) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_slashingDeltaLastUpdated, _slashingDeltaMaxAge);
        }
        return _cachedTotalStaked;
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _providerConfig;
    }

    /// @inheritdoc IStakingManager
    function getActivatedAttesterCount() external view override returns (uint256) {
        return activatedAttesterCount;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakeCount() external view override returns (uint256) {
        return pendingUnstakeCount;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL VIEW FUNCTIONS 2
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function getSlashingDelta() external view override returns (uint256 slashingDelta) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_slashingDeltaLastUpdated, _slashingDeltaMaxAge);
        }
        return _slashingDelta;
    }

    /// @inheritdoc IStakingManager
    function getSlashingDeltaLiveness()
        external
        view
        override
        returns (uint256 lastUpdated, uint256 maxAge, bool isStale)
    {
        lastUpdated = _slashingDeltaLastUpdated;
        maxAge = _slashingDeltaMaxAge;
        isStale = _isSlashingDeltaStale();
        return (lastUpdated, maxAge, isStale);
    }

    /// @inheritdoc IStakingManager
    function pendingUnstakes() external view override returns (uint256) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_slashingDeltaLastUpdated, _slashingDeltaMaxAge);
        }
        return _cachedPendingUnstakeAmount;
    }

    /// @inheritdoc IStakingManager
    function hasExitableUnstakes() external view override returns (bool) {
        if (_isSlashingDeltaStale()) {
            revert StakingManager__SlashingDeltaStale(_slashingDeltaLastUpdated, _slashingDeltaMaxAge);
        }
        return _cachedWithdrawableAmount != 0;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function getUnstakeCursor() external pure override returns (uint256 cursor) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function setGasThreshold(uint256 threshold) external pure override {
        threshold;
    }

    /// @inheritdoc IStakingManager
    function getClaimableRewards() external pure override returns (uint256 claimableRewards) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function getUnstakedFunds() external pure override returns (uint256 received) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function harvestRewards() external pure override returns (uint256 harvested) {
        return 0;
    }

    /// @inheritdoc IStakingManager
    function isUnstakePending(address) external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc IStakingManager
    function syncAttesters() external pure override {
        // No-op for mock
        return;
    }

    function _isSlashingDeltaStale() internal view returns (bool) {
        uint256 lastUpdated = _slashingDeltaLastUpdated;
        if (lastUpdated == 0) {
            return true;
        }
        return block.timestamp - lastUpdated > _slashingDeltaMaxAge;
    }
}
