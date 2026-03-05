// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title RolesLib
/// @notice Shared role identifiers used across protocol modules.
/// @author Olla Core contributors
library RolesLib {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");
}
