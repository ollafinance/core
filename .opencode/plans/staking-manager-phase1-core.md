# Phase 1: StakingManager Core Functionality

**Issue**: #13 - feat: StakingManager core functionality

## Scope

From issue #13:
- Stake (function shell)
- Unstake (function shell)
- Harvest
- Access control

## Aztec Dependencies

Import BN254 types from Aztec contracts instead of creating our own:

```solidity
import { G1Point, G2Point } from "@az/shared/libraries/BN254Lib.sol";
```

## Implementation Steps

### Step 1: Create QueueLib

Create `contracts/src/libraries/QueueLib.sol`:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IStakingManager } from "src/interfaces/IStakingManager.sol";

struct Queue {
    mapping(uint256 index => IStakingManager.KeyStore keyStore) keyStores;
    uint128 first;
    uint128 last;
}

library QueueLib {
    error QueueIsEmpty();
    error QueueIndexOutOfBounds();

    function init(Queue storage _self) internal {
        _self.first = 1;
        _self.last = 1;
    }

    function enqueue(Queue storage _self, IStakingManager.KeyStore memory _keyStore) internal returns (uint128) {
        uint128 queueLocation = _self.last;
        _self.keyStores[queueLocation] = _keyStore;
        _self.last = queueLocation + 1;
        return queueLocation;
    }

    function dequeue(Queue storage _self) internal returns (IStakingManager.KeyStore memory) {
        require(_self.last > _self.first, QueueIsEmpty());
        IStakingManager.KeyStore memory keyStore = _self.keyStores[_self.first];
        _self.first += 1;
        return keyStore;
    }

    function length(Queue storage _self) internal view returns (uint128) {
        return _self.last - _self.first;
    }

    function getFirstIndex(Queue storage _self) internal view returns (uint128) {
        return _self.first;
    }

    function getLastIndex(Queue storage _self) internal view returns (uint128) {
        return _self.last;
    }

    function getValueAtIndex(Queue storage _self, uint128 _index)
        internal
        view
        returns (IStakingManager.KeyStore memory)
    {
        require(_index >= _self.first && _index < _self.last, QueueIndexOutOfBounds());
        return _self.keyStores[_index];
    }
}
```

### Step 2: Expand IStakingManager Interface

Modify `contracts/src/interfaces/IStakingManager.sol`:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

// Import BN254 types from Aztec contracts
import { G1Point, G2Point } from "@az/shared/libraries/BN254Lib.sol";

/// @title IStakingManager
/// @notice Interface for staking delegation and validator key management.
/// @author Olla Core contributors
interface IStakingManager {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct KeyStore {
        address attester;
        G1Point publicKeyG1;
        G2Point publicKeyG2;
        G1Point proofOfPossession;
    }

    struct ProviderConfig {
        address admin;
        address rewardsRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProviderSet(address indexed admin, address indexed rewardsRecipient);
    event KeysAddedToProvider(address[] attesters);
    event StakedWithProvider(address indexed attester, uint256 amount);
    event UnstakeInitiated(address indexed attester, uint256 amount);
    event UnstakedFundsClaimed(uint256 amount);
    event RewardsHarvested(uint256 amount);
    event QueueDripped(address indexed attester);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error StakingManager__ZeroAddress();
    error StakingManager__ZeroAmount();
    error StakingManager__Unauthorized();
    error StakingManager__InsufficientStake();
    error StakingManager__QueueEmpty();
    error StakingManager__InsufficientKeys();

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stakes assets with the staking provider.
    /// @param amount The amount to stake.
    function stake(uint256 amount) external;

    /// @notice Initiates an unstake with the staking provider.
    /// @param amount The amount to unstake.
    function unStake(uint256 amount) external;

    /// @notice Claims matured unstaked funds back to core.
    /// @return received The amount of assets received.
    function getUnstakedFunds() external returns (uint256 received);

    /// @notice Claims sequencer rewards to RewardsVault.
    /// @return harvested The amount of rewards harvested.
    function harvestRewards() external returns (uint256 harvested);

    /*//////////////////////////////////////////////////////////////
                        PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds validator keys to the provider queue.
    /// @param keyStores The validator key stores to add.
    function addKeysToProvider(KeyStore[] calldata keyStores) external;

    /// @notice Removes keys from the front of the queue.
    /// @param count The number of keys to remove.
    function dripQueue(uint256 count) external;

    /// @notice Sets the provider rewards recipient address.
    /// @param rewardsRecipient The new rewards recipient.
    function setProviderRewardsRecipient(address rewardsRecipient) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the current total staked principal.
    /// @return The total staked amount.
    function totalStaked() external view returns (uint256);

    /// @notice Returns the pending unstakes amount.
    /// @return The pending unstakes.
    function getPendingUnstakes() external view returns (uint256);

    /// @notice Returns the provider queue length.
    /// @return The number of keys in the queue.
    function getQueueLength() external view returns (uint256);

    /// @notice Returns the provider configuration.
    /// @return The provider config struct.
    function getProviderConfig() external view returns (ProviderConfig memory);
}
```

### Step 3: Create MockAztecRollup

Create `contracts/src/mocks/MockAztecRollup.sol`:

The mock should implement the `IStaking` interface from Aztec:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { G1Point, G2Point } from "@az/shared/libraries/BN254Lib.sol";
import { Exit, Status } from "@az/core/libraries/rollup/StakingLib.sol";
import { Timestamp } from "@az/shared/libraries/TimeMath.sol";

/// @title MockAztecRollup
/// @notice Mock Aztec rollup for testing staking flows.
/// @dev Implements a subset of IStaking interface for testing.
/// @author Olla Core contributors
contract MockAztecRollup {
    IERC20 public stakingAsset;
    uint256 public activationThreshold;

    mapping(address attester => uint256 stake) public stakes;
    mapping(address attester => address withdrawer) public withdrawers;
    mapping(address attester => Exit) public exits;
    mapping(address sequencer => uint256 rewards) public pendingRewards;

    event Deposit(
        address indexed attester,
        address indexed withdrawer,
        G1Point publicKeyInG1,
        G2Point publicKeyInG2,
        G1Point proofOfPossession,
        uint256 amount
    );
    event WithdrawInitiated(address indexed attester, address indexed recipient, uint256 amount);
    event WithdrawFinalized(address indexed attester, address indexed recipient, uint256 amount);

    constructor(IERC20 _stakingAsset, uint256 _activationThreshold) {
        stakingAsset = _stakingAsset;
        activationThreshold = _activationThreshold;
    }

    function deposit(
        address _attester,
        address _withdrawer,
        G1Point memory _publicKeyInG1,
        G2Point memory _publicKeyInG2,
        G1Point memory _proofOfPossession,
        bool
    ) external {
        stakingAsset.transferFrom(msg.sender, address(this), activationThreshold);
        stakes[_attester] = activationThreshold;
        withdrawers[_attester] = _withdrawer;
        emit Deposit(_attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, activationThreshold);
    }

    function initiateWithdraw(address _attester, address _recipient) external returns (bool) {
        require(withdrawers[_attester] == msg.sender, "Not withdrawer");
        require(!exits[_attester].exists, "Already exiting");
        
        uint256 amount = stakes[_attester];
        exits[_attester] = Exit({
            withdrawalId: 0,
            amount: amount,
            exitableAt: Timestamp.wrap(block.timestamp), // Immediate for testing
            recipientOrWithdrawer: _recipient,
            isRecipient: true,
            exists: true
        });
        
        emit WithdrawInitiated(_attester, _recipient, amount);
        return true;
    }

    function finalizeWithdraw(address _attester) external {
        Exit memory exit = exits[_attester];
        require(exit.exists, "Not exiting");
        require(exit.isRecipient, "Initiate first");
        require(Timestamp.unwrap(exit.exitableAt) <= block.timestamp, "Not ready");
        
        uint256 amount = exit.amount;
        stakes[_attester] = 0;
        delete exits[_attester];
        
        stakingAsset.transfer(exit.recipientOrWithdrawer, amount);
        emit WithdrawFinalized(_attester, exit.recipientOrWithdrawer, amount);
    }

    function getExit(address _attester) external view returns (Exit memory) {
        return exits[_attester];
    }

    function getStatus(address _attester) external view returns (Status) {
        if (exits[_attester].exists) {
            return exits[_attester].isRecipient ? Status.EXITING : Status.ZOMBIE;
        }
        return stakes[_attester] > 0 ? Status.VALIDATING : Status.NONE;
    }

    function getActivationThreshold() external view returns (uint256) {
        return activationThreshold;
    }

    function getActiveAttesterCount() external view returns (uint256) {
        // Simplified for testing
        return 0;
    }

    // Test helpers
    function setRewards(address _sequencer, uint256 _amount) external {
        pendingRewards[_sequencer] = _amount;
    }

    function setActivationThreshold(uint256 _threshold) external {
        activationThreshold = _threshold;
    }
}
```

### Step 4: Create StakingManager Contract

Create `contracts/src/core/StakingManager.sol`:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { AccessControl } from "@oz/access/AccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { Queue, QueueLib } from "src/libraries/QueueLib.sol";
// Import Aztec types
import { G1Point, G2Point } from "@az/shared/libraries/BN254Lib.sol";
import { IStaking } from "@az/core/interfaces/IStaking.sol";

/// @title StakingManager
/// @notice Manages staking delegation, validator keys, and reward harvesting.
/// @author Olla Core contributors
contract StakingManager is IStakingManager, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using QueueLib for Queue;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant CORE_ROLE = keccak256("CORE_ROLE");
    bytes32 public constant STAKING_PROVIDER_ADMIN_ROLE = keccak256("STAKING_PROVIDER_ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable stakingAsset;
    IStaking public immutable rollup;
    address public immutable rewardsVault;
    address public immutable core;

    ProviderConfig private _provider;
    Queue private _providerQueue;
    uint256 private _totalStakedPrincipal;
    uint256 private _pendingUnstakes;

    // Track active validators for unstaking
    address[] private _activeValidators;
    mapping(address attester => uint256 index) private _validatorIndex;
    mapping(address attester => bool isActive) private _isActiveValidator;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _stakingAsset,
        address _rollup,
        address _rewardsVault,
        address _core,
        address _providerAdmin,
        address _providerRewardsRecipient,
        address _defaultAdmin
    ) {
        if (address(_stakingAsset) == address(0)) revert StakingManager__ZeroAddress();
        if (_rollup == address(0)) revert StakingManager__ZeroAddress();
        if (_rewardsVault == address(0)) revert StakingManager__ZeroAddress();
        if (_core == address(0)) revert StakingManager__ZeroAddress();
        if (_providerAdmin == address(0)) revert StakingManager__ZeroAddress();
        if (_defaultAdmin == address(0)) revert StakingManager__ZeroAddress();

        stakingAsset = _stakingAsset;
        rollup = IStaking(_rollup);
        rewardsVault = _rewardsVault;
        core = _core;

        _provider = ProviderConfig({
            admin: _providerAdmin,
            rewardsRecipient: _providerRewardsRecipient
        });

        _providerQueue.init();

        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(CORE_ROLE, _core);
        _grantRole(STAKING_PROVIDER_ADMIN_ROLE, _providerAdmin);

        emit ProviderSet(_providerAdmin, _providerRewardsRecipient);
    }

    // ... rest of implementation same as before, but using IStaking interface
}
```

### Step 5: Create Unit Tests

Tests use the mock rollup and verify interactions:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "@forge-std/Test.sol";
import { StakingManager } from "src/core/StakingManager.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/mocks/MockAztecRollup.sol";
import { G1Point, G2Point } from "@az/shared/libraries/BN254Lib.sol";

contract StakingManagerTest is Test {
    // ... test setup using @az imports for BN254 types
    
    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(i + 1)),
                publicKeyG1: G1Point({ x: i, y: i + 1 }),
                publicKeyG2: G2Point({ x0: i, x1: i + 1, y0: i + 2, y1: i + 3 }),
                proofOfPossession: G1Point({ x: i + 10, y: i + 11 })
            });
        }
        return keys;
    }
}
```

## Test Cases from Issue #13

- [x] Stake increases totalStaked
- [x] Unstake decreases totalStaked (via pendingUnstakes)
- [ ] Harvest increases rewards bucket (placeholder for now)
- [x] Unauthorized calls revert

## Acceptance Criteria

- [x] Only authorized callers execute operations
- [x] No user balance custody (assets flow through, not held)

## Verification

```bash
# Run tests
forge test --match-contract StakingManagerTest -vvv

# Check coverage
forge coverage --match-contract StakingManager
```
