// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";

/// @title MockAccountingStakingManager
/// @notice Test mock for IStakingManager that allows setting claimable rewards, slashing delta, and staked amounts.
contract MockAccountingStakingManager is IStakingManager {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IERC20 public rewardsToken;
    address public rewardsVault;
    uint256 public claimableRewards;
    uint256 public slashingDelta;
    uint256 public totalStakedAmount;
    uint256 public harvestedRewards;
    address public providerRewardsRecipient;
    address public providerAdmin;

    /*//////////////////////////////////////////////////////////////
                          TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function setRewardsToken(IERC20 token) external {
        rewardsToken = token;
    }

    function setRewardsVault(address vault) external {
        rewardsVault = vault;
    }

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

    function setProviderRewardsRecipient(address recipient) external {
        providerRewardsRecipient = recipient;
    }

    function setProviderAdmin(address admin) external {
        providerAdmin = admin;
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

    function harvestRewards() external override returns (uint256 harvested) {
        harvested = harvestedRewards;
        // Actually transfer tokens to rewards vault to simulate real harvest
        if (harvested > 0 && address(rewardsToken) != address(0) && rewardsVault != address(0)) {
            // Cast to MockAztec and mint tokens to this contract first, then transfer to vault
            MockAztec(address(rewardsToken)).mint(address(this), harvested);
            rewardsToken.transfer(rewardsVault, harvested);
        }
        return harvested;
    }

    function getSlashingDelta() external view override returns (uint256) {
        return slashingDelta;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getClaimableRewards() external view override returns (uint256) {
        return claimableRewards;
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

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }

    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return ProviderConfig({ admin: providerAdmin, rewardsRecipient: providerRewardsRecipient });
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

    function initialize(IERC20, address, address, address, address, address) external pure override { }
}
