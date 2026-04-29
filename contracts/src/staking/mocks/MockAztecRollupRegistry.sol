// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IAztecRewardDistributor } from "src/staking/interfaces/IAztecRewardDistributor.sol";
import { IMockAztecRollupRegistry } from "src/staking/mocks/IMockAztecRollupRegistry.sol";
import { MockAztecRewardDistributor } from "src/staking/mocks/MockAztecRewardDistributor.sol";

/// @title MockRollupRegistry
/// @notice Mock implementation of the Aztec Rollup Registry for testing.
/// @dev Always returns the canonical rollup address set at construction.
/// @author Olla Core contributors
contract MockAztecRollupRegistry is IMockAztecRollupRegistry {
    /// @dev The canonical rollup address.
    address private _canonicalRollup;

    /// @dev The governance address.
    address private _governance;

    /// @dev The reward distributor address.
    IAztecRewardDistributor private _rewardDistributor;

    /// @notice Constructs the MockAztecRollupRegistry with a reward asset.
    /// @param canonicalRollup_ The address of the canonical rollup.
    /// @param rewardAsset_ The reward distributor asset.
    constructor(address canonicalRollup_, IERC20 rewardAsset_) {
        _canonicalRollup = canonicalRollup_;
        _governance = msg.sender;
        _rewardDistributor = new MockAztecRewardDistributor(rewardAsset_);
    }

    /// @inheritdoc IMockAztecRollupRegistry
    function setCanonicalRollup(address canonicalRollup_) external override {
        _canonicalRollup = canonicalRollup_;
    }

    /// @inheritdoc IMockAztecRollupRegistry
    function setRewardDistributor(IAztecRewardDistributor rewardDistributor_) external override {
        _rewardDistributor = rewardDistributor_;
    }

    /// @notice Returns the canonical (latest) rollup address.
    /// @return The address of the canonical rollup contract.
    function getCanonicalRollup() external view override returns (address) {
        return _canonicalRollup;
    }

    /// @notice Returns the governance address.
    /// @return The address of the governance contract.
    function getGovernance() external view override returns (address) {
        return _governance;
    }

    /// @notice Returns the reward distributor contract.
    /// @return The reward distributor contract.
    function getRewardDistributor() external view override returns (IAztecRewardDistributor) {
        return _rewardDistributor;
    }

    /// @notice Sets the governance address (for testing).
    /// @param governance_ The new governance address.
    function setGovernance(address governance_) external {
        _governance = governance_;
    }
}
