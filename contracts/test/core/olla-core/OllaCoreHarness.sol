// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedComputeNetFlows(IOllaCore.FlowCounters memory flows)
        external
        pure
        returns (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        return _computeNetFlows(flows);
    }

    function exposedComputeTotalAssets(
        IOllaCore.AccountingState memory buckets,
        uint256 bufferedAssets,
        uint256 pendingWithdrawals
    ) external pure returns (uint256 totalAssets_) {
        return _computeTotalAssets(buckets, bufferedAssets, pendingWithdrawals);
    }

    function exposedComputeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, int256 netFlows)
        external
        pure
        returns (uint256 grossRewards, int256 grossRewardsSigned)
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

    function exposedWithdrawalRate() external view returns (uint256) {
        return _withdrawalRate(IOllaVault(this.vault()));
    }
}
