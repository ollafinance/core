// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";

contract OllaCoreHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedIncreaseBuffered(uint256 amount) external {
        _increaseBuffered(amount);
    }

    function exposedApplyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsVaultBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) external {
        _applyAccountingUpdates(
            newStakedPrincipal, newRewardsVaultBalance, newClaimableRewards, newRewardsDelta, newSlashingDelta
        );
    }

    function exposedSyncBufferedWithBalance() external {
        _syncBufferedWithBalance();
    }

    function exposedComputeNetFlows(IOllaCore.FlowCounters memory flows)
        external
        pure
        returns (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        return _computeNetFlows(flows);
    }

    function exposedComputeTotalAssets(IOllaCore.AccountingState memory buckets)
        external
        pure
        returns (uint256 totalAssets_)
    {
        return _computeTotalAssets(buckets);
    }

    function exposedComputeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, int256 netFlows)
        external
        pure
        returns (uint256 grossRewards)
    {
        return _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
    }

    function exposedCalculateProtocolFees(uint256 grossAssetRewards)
        external
        view
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        return _calculateProtocolFees(grossAssetRewards);
    }
}
