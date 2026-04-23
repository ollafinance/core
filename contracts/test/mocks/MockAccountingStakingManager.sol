// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";

import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";

/// @title MockAccountingStakingManager
/// @notice Test mock for IStakingManager that allows setting claimable rewards, slashing delta, and staked amounts.
contract MockAccountingStakingManager is IStakingManager {
    using SafeERC20 for IERC20;
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IERC20 public rewardsToken;
    address public rewardsAccumulator;
    uint256 public claimableRewards;
    uint256 public slashingDelta;
    uint256 public totalStakedAmount;
    uint256 public harvestedRewards;
    IERC20 public unstakedToken;
    uint256 public unstakedAmount;
    uint256 public unstakedExitAmountOverride;
    bool public useUnstakedExitAmountOverride;
    uint256 public pendingUnstakeAmount;
    bool public hasFinalizedUnstakesValue;
    uint256 public activatedAttesterCount;
    uint256 public pendingUnstakeCount;
    uint256 public lastUnstakeAmount;
    uint256 public unstakeReturnAmount;
    bool public useUnstakeReturnAmount;
    uint256 public gasBurnTarget;
    address public providerRewardsRecipient;
    address public providerAdmin;
    uint256 public stakeReturnAmount;
    bool public useStakeReturnAmount;
    bool public allowStakeReturnExceeds;

    /*//////////////////////////////////////////////////////////////
                          TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    function setRewardsToken(IERC20 token) external {
        rewardsToken = token;
    }

    function setRewardsAccumulator(address vault) external {
        rewardsAccumulator = vault;
    }

    function setClaimableRewards(uint256 value) external {
        claimableRewards = value;
    }

    function setSlashingDelta(uint256 value) external {
        // Mirror real StakingManager behaviour: slashing reduces stakedAmount AND
        // increments slashingDelta. Compute the incremental increase and deduct it
        // from totalStakedAmount so that totalStaked() is net-of-slashing.
        uint256 increase = value > slashingDelta ? value - slashingDelta : 0;
        slashingDelta = value;
        if (increase > 0) {
            totalStakedAmount = totalStakedAmount >= increase ? totalStakedAmount - increase : 0;
        }
    }

    function setTotalStaked(uint256 value) external {
        totalStakedAmount = value;
    }

    function setHarvestedRewards(uint256 value) external {
        harvestedRewards = value;
    }

    function setUnstakedToken(IERC20 token) external {
        unstakedToken = token;
    }

    function setUnstakedAmount(uint256 value) external {
        unstakedAmount = value;
    }

    function setUnstakedExitAmountOverride(uint256 value) external {
        unstakedExitAmountOverride = value;
        useUnstakedExitAmountOverride = true;
    }

    function setGasBurnTarget(uint256 target) external {
        gasBurnTarget = target;
    }

    function setPendingUnstakes(uint256 value) external {
        pendingUnstakeAmount = value;
    }

    function setWithdrawableUnstakes(uint256 value) external {
        hasFinalizedUnstakesValue = value != 0;
    }

    function setActivatedAttesterCount(uint256 value) external {
        activatedAttesterCount = value;
    }

    function setPendingUnstakeCount(uint256 value) external {
        pendingUnstakeCount = value;
    }

    function setUnstakeReturnAmount(uint256 value) external {
        unstakeReturnAmount = value;
        useUnstakeReturnAmount = true;
    }

    function clearUnstakeReturnAmount() external {
        useUnstakeReturnAmount = false;
    }

    function setProviderRewardsRecipient(address recipient) external {
        providerRewardsRecipient = recipient;
    }

    function setProviderAdmin(address admin) external {
        providerAdmin = admin;
    }

    function setStakeReturnAmount(uint256 amount) external {
        stakeReturnAmount = amount;
        useStakeReturnAmount = true;
    }

    function clearStakeReturnAmount() external {
        useStakeReturnAmount = false;
    }

    function setAllowStakeReturnExceeds(bool allow) external {
        allowStakeReturnExceeds = allow;
    }

    /*//////////////////////////////////////////////////////////////
                          CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setGasThreshold(uint256) external override { }

    function stake(uint256 amount) external virtual override returns (uint256 stakedAmount) {
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
        IERC20 token = rewardsToken;
        if (address(token) == address(0)) {
            return 0;
        }
        uint256 transferAmount = actualAmount;
        if (actualAmount > amount) {
            transferAmount = amount;
        }
        if (transferAmount != 0) {
            token.safeTransferFrom(msg.sender, address(this), transferAmount);
        }
        return actualAmount;
    }

    function unstake(uint256 amount) external override returns (uint256 returnedAmount) {
        lastUnstakeAmount = amount;
        if (useUnstakeReturnAmount) {
            returnedAmount = unstakeReturnAmount;
            if (returnedAmount > amount) {
                returnedAmount = amount;
            }
            return returnedAmount;
        }
        return amount;
    }

    function refreshAttesterState(address[] calldata) external virtual override { }

    function purgeFailedQueueEntry(address) external virtual override { }

    function getUnstakedFunds() public virtual override returns (uint256 received, uint256 exitAmount) {
        uint256 target = gasBurnTarget;
        if (target != 0) {
            uint256 safetyMargin = 25_000;
            uint256 burnTarget = target + safetyMargin;
            while (gasleft() > burnTarget) {
                assembly {
                    mstore(0x00, add(mload(0x00), 1))
                }
            }
        }

        uint256 amount = unstakedAmount;
        if (amount == 0) {
            return (0, 0);
        }

        IERC20 token = unstakedToken;
        if (address(token) == address(0)) {
            return (0, 0);
        }

        unstakedAmount = 0;
        token.safeTransfer(msg.sender, amount);
        uint256 reportedExit = useUnstakedExitAmountOverride ? unstakedExitAmountOverride : amount;
        return (amount, reportedExit);
    }

    function harvestRewards() external virtual override returns (uint256 harvested) {
        harvested = harvestedRewards;
        // Actually transfer tokens to rewards vault to simulate real harvest
        if (harvested > 0 && address(rewardsToken) != address(0) && rewardsAccumulator != address(0)) {
            // Cast to MockAztec and mint tokens to this contract first, then transfer to vault
            MockAztec(address(rewardsToken)).mint(address(this), harvested);
            rewardsToken.safeTransfer(rewardsAccumulator, harvested);
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
        return StakingState({
            slashingDelta: slashingDelta, stakedAmount: totalStakedAmount, pendingUnstakeAmount: pendingUnstakeAmount
        });
    }

    function pendingUnstakes() external view override returns (uint256) {
        return pendingUnstakeAmount;
    }

    function hasFinalizedUnstakes() external view override returns (bool) {
        return hasFinalizedUnstakesValue;
    }

    function core() external pure virtual override returns (address) {
        return address(0);
    }

    function canStake(uint256) external view override returns (bool) {
        if (useStakeReturnAmount) return stakeReturnAmount > 0;
        return true;
    }

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }

    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return ProviderConfig({ rewardsRecipient: providerRewardsRecipient });
    }

    function getActivatedAttesterCount() external view override returns (uint256) {
        return activatedAttesterCount;
    }

    function getPendingUnstakeCount() external view override returns (uint256) {
        return pendingUnstakeCount;
    }

    function isUnstakePending(address) external pure override returns (bool) {
        return false;
    }

    function initialize(IERC20, address, address, address, address, address) external pure override { }
}
