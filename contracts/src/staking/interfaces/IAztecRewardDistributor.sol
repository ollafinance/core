// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

/// @title IAztecRewardDistributor
/// @notice Minimal interface for the Aztec RewardDistributor contract.
interface IAztecRewardDistributor {
    /// @notice Returns the ERC20 asset distributed as sequencer rewards.
    /// @return The reward asset token.
    function ASSET() external view returns (IERC20);
}
