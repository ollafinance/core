// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";

/// @title MockAccountingStakingManager
/// @notice Test mock for IStakingManager that allows setting claimable rewards, slashing delta, and staked amounts.
contract MockAccountingStakingManager is IStakingManager {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public claimableRewards;
    uint256 public slashingDelta;
    uint256 public totalStakedAmount;
    uint256 public harvestedRewards;
    address public providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                          TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function setClaimableRewards(uint256 value) external {
        claimableRewards = value;
    }

    function setSlashingDelta(uint256 value) external {
        slashingDelta = value;
    }

    function setTotalStaked(uint256 value) external {
        totalStakedAmount = value;
    }

    function setHarvestedRewards(uint256 value) external {
        harvestedRewards = value;
    }

    function setProviderRewardsRecipient(address recipient) external override {
        providerRewardsRecipient = recipient;
    }

    /*//////////////////////////////////////////////////////////////
                         CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function stake(uint256) external pure override { }

    function unstake(uint256) external pure override { }

    function cleanActivatedAttesters() external pure override { }

    function getUnstakedFunds() external pure override returns (uint256 received) {
        return received;
    }

    function harvestRewards() external view override returns (uint256 harvested) {
        return harvestedRewards;
    }

    /*//////////////////////////////////////////////////////////////
                         PROVIDER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addKeysToProvider(KeyStore[] calldata) external pure override { }

    function dripQueue(uint256) external pure override { }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getClaimableRewards() external view override returns (uint256) {
        return claimableRewards;
    }

    function getSlashingDelta() external view override returns (uint256) {
        return slashingDelta;
    }

    function totalStaked() external view override returns (uint256) {
        return totalStakedAmount;
    }

    function getStakingState() external view override returns (StakingState memory) {
        return StakingState({ stakedAmount: totalStakedAmount, pendingUnstakeAmount: 0, withdrawableAmount: 0 });
    }

    function core() external pure override returns (address) {
        return address(0);
    }

    function getQueueLength() external pure override returns (uint256) {
        return 0;
    }

    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return ProviderConfig({ admin: address(0), rewardsRecipient: providerRewardsRecipient });
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

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function initialize(IERC20, address, address, address, address, address, address) external pure override { }
}
