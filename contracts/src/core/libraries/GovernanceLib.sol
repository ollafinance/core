// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

/// @title GovernanceLib
/// @notice Extracts governance setter logic from OllaCore to reduce bytecode.
/// @dev Uses external functions with storage references, invoked via automatic DELEGATECALL.
///      Only functions with external calls or struct interactions are extracted here --
///      scalar-only setters stay inline in OllaCore because the DELEGATECALL overhead
///      exceeds the body savings under via_ir optimization.
/// @author Olla Core contributors
library GovernanceLib {
    using SafeERC20 for IERC20;

    /// @notice Validates and sets the safety module on the CoreModules struct.
    /// @param modules The CoreModules storage reference.
    /// @param newSafetyModule The new safety module address.
    /// @return oldSafetyModule The previous safety module address.
    function setSafetyModule(IOllaCore.CoreModules storage modules, address newSafetyModule)
        external
        returns (address oldSafetyModule)
    {
        if (newSafetyModule == address(0)) {
            revert IOllaCore.OllaCore__ZeroAddress("newSafetyModule");
        }
        if (ISafetyModule(newSafetyModule).CORE() != address(this)) {
            revert IOllaCore.OllaCore__InvalidSafetyModule(newSafetyModule);
        }
        oldSafetyModule = modules.safetyModule;
        modules.safetyModule = newSafetyModule;

        return oldSafetyModule;
    }

    /// @notice Propagates gas threshold to staking manager.
    /// @dev WithdrawalQueue gas threshold is set separately by governance via DEFAULT_ADMIN_ROLE.
    /// @param modules The CoreModules storage reference.
    /// @param newThreshold The new gas threshold.
    function propagateGasThreshold(IOllaCore.CoreModules storage modules, uint256 newThreshold) external {
        modules.stakingManager.setGasThreshold(newThreshold);
    }
}
