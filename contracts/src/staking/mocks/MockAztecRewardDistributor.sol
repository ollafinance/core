// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IAztecRewardDistributor } from "src/staking/interfaces/IAztecRewardDistributor.sol";

/// @title MockAztecRewardDistributor
/// @notice Mock implementation of the Aztec RewardDistributor for testing.
contract MockAztecRewardDistributor is IAztecRewardDistributor {
    IERC20 public immutable override ASSET;

    constructor(IERC20 asset_) {
        ASSET = asset_;
    }
}
