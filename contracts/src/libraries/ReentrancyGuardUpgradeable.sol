// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";

/// @title ReentrancyGuardUpgradeable
/// @notice Upgradeable variant of OpenZeppelin's ReentrancyGuard.
/// @dev Uses an initializer instead of a constructor for proxy compatibility.
/// @author Olla Core contributors
abstract contract ReentrancyGuardUpgradeable is Initializable {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;
    uint256[49] private __gap;

    /// @notice Thrown when a reentrant call is detected.
    error ReentrancyGuardReentrantCall();

    /// @notice Prevents a contract from calling itself, directly or indirectly.
    modifier nonReentrant() {
        if (_status == _ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @notice View-only reentrancy guard.
    modifier nonReentrantView() {
        if (_status == _ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }
        _;
    }

    // solhint-disable-next-line func-name-mixedcase
    function __ReentrancyGuard_init() internal onlyInitializing {
        _status = _NOT_ENTERED;
    }
}
