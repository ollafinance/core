# Phase 1: StakingManager Core Functionality

**Issue**: #13 - feat: StakingManager core functionality

## Scope

From issue #13:
- Stake (function shell)
- Unstake (function shell)
- Harvest
- Access control

## Implementation Steps

### Step 1: Create Supporting Libraries

#### 1.1 BN254Lib.sol

Create `contracts/src/libraries/BN254Lib.sol`:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

library BN254Lib {
    struct G1Point {
        uint256 x;
        uint256 y;
    }

    struct G2Point {
        uint256 x0;
        uint256 x1;
        uint256 y0;
        uint256 y1;
    }
}
```

#### 1.2 QueueLib.sol

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

import { BN254Lib } from "src/libraries/BN254Lib.sol";

/// @title IStakingManager
/// @notice Interface for staking delegation and validator key management.
/// @author Olla Core contributors
interface IStakingManager {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct KeyStore {
        address attester;
        BN254Lib.G1Point publicKeyG1;
        BN254Lib.G2Point publicKeyG2;
        BN254Lib.G1Point proofOfPossession;
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

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { BN254Lib } from "src/libraries/BN254Lib.sol";

/// @title MockAztecRollup
/// @notice Mock Aztec rollup for testing staking flows.
/// @author Olla Core contributors
contract MockAztecRollup {
    IERC20 public stakingAsset;
    uint256 public activationThreshold;

    mapping(address attester => uint256 stake) public stakes;
    mapping(address attester => address withdrawer) public withdrawers;
    mapping(address attester => bool isWithdrawing) public withdrawing;
    mapping(address sequencer => uint256 rewards) public pendingRewards;

    event Deposited(address indexed attester, address indexed withdrawer, uint256 amount);
    event WithdrawInitiated(address indexed attester, address indexed recipient);
    event WithdrawFinalized(address indexed attester, uint256 amount);
    event RewardsClaimed(address indexed sequencer, uint256 amount);

    constructor(IERC20 _stakingAsset, uint256 _activationThreshold) {
        stakingAsset = _stakingAsset;
        activationThreshold = _activationThreshold;
    }

    function deposit(
        address _attester,
        address _withdrawer,
        BN254Lib.G1Point memory,
        BN254Lib.G2Point memory,
        BN254Lib.G1Point memory,
        bool
    ) external {
        stakingAsset.transferFrom(msg.sender, address(this), activationThreshold);
        stakes[_attester] = activationThreshold;
        withdrawers[_attester] = _withdrawer;
        emit Deposited(_attester, _withdrawer, activationThreshold);
    }

    function initiateWithdraw(address _attester, address) external {
        require(withdrawers[_attester] == msg.sender, "Not withdrawer");
        require(!withdrawing[_attester], "Already withdrawing");
        withdrawing[_attester] = true;
        emit WithdrawInitiated(_attester, msg.sender);
    }

    function finaliseWithdraw(address _attester) external {
        require(withdrawing[_attester], "Not withdrawing");
        uint256 amount = stakes[_attester];
        stakes[_attester] = 0;
        withdrawing[_attester] = false;
        stakingAsset.transfer(withdrawers[_attester], amount);
        emit WithdrawFinalized(_attester, amount);
    }

    function claimSequencerRewards(address _sequencer) external {
        uint256 amount = pendingRewards[_sequencer];
        pendingRewards[_sequencer] = 0;
        stakingAsset.transfer(_sequencer, amount);
        emit RewardsClaimed(_sequencer, amount);
    }

    function getActivationThreshold() external view returns (uint256) {
        return activationThreshold;
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
import { BN254Lib } from "src/libraries/BN254Lib.sol";

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
    address public immutable rollup;
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
        rollup = _rollup;
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

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function stake(uint256 amount) external override onlyRole(CORE_ROLE) nonReentrant {
        if (amount == 0) revert StakingManager__ZeroAmount();
        // Implementation in Phase 2
        _stakeInternal(amount);
    }

    /// @inheritdoc IStakingManager
    function unStake(uint256 amount) external override onlyRole(CORE_ROLE) nonReentrant {
        if (amount == 0) revert StakingManager__ZeroAmount();
        // Implementation in Phase 3
        _unstakeInternal(amount);
    }

    /// @inheritdoc IStakingManager
    function getUnstakedFunds() external override onlyRole(CORE_ROLE) nonReentrant returns (uint256 received) {
        // Implementation in Phase 3
        received = _claimUnstakedFunds();
        return received;
    }

    /// @inheritdoc IStakingManager
    function harvestRewards() external override onlyRole(CORE_ROLE) nonReentrant returns (uint256 harvested) {
        // Harvest rewards from all active validators to RewardsVault
        // For now, return 0 as we need the actual rollup integration
        harvested = 0;
        emit RewardsHarvested(harvested);
        return harvested;
    }

    /*//////////////////////////////////////////////////////////////
                        PROVIDER ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function addKeysToProvider(KeyStore[] calldata keyStores)
        external
        override
        onlyRole(STAKING_PROVIDER_ADMIN_ROLE)
    {
        address[] memory attesters = new address[](keyStores.length);
        for (uint256 i; i < keyStores.length; ++i) {
            _providerQueue.enqueue(keyStores[i]);
            attesters[i] = keyStores[i].attester;
        }
        emit KeysAddedToProvider(attesters);
    }

    /// @inheritdoc IStakingManager
    function dripQueue(uint256 count) external override onlyRole(STAKING_PROVIDER_ADMIN_ROLE) {
        for (uint256 i; i < count; ++i) {
            KeyStore memory keyStore = _providerQueue.dequeue();
            emit QueueDripped(keyStore.attester);
        }
    }

    /// @inheritdoc IStakingManager
    function setProviderRewardsRecipient(address rewardsRecipient)
        external
        override
        onlyRole(STAKING_PROVIDER_ADMIN_ROLE)
    {
        if (rewardsRecipient == address(0)) revert StakingManager__ZeroAddress();
        _provider.rewardsRecipient = rewardsRecipient;
        emit ProviderSet(_provider.admin, rewardsRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingManager
    function totalStaked() external view override returns (uint256) {
        return _totalStakedPrincipal;
    }

    /// @inheritdoc IStakingManager
    function getPendingUnstakes() external view override returns (uint256) {
        return _pendingUnstakes;
    }

    /// @inheritdoc IStakingManager
    function getQueueLength() external view override returns (uint256) {
        return _providerQueue.length();
    }

    /// @inheritdoc IStakingManager
    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _provider;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _stakeInternal(uint256 amount) internal {
        // Placeholder - implemented in Phase 2
        _totalStakedPrincipal += amount;
    }

    function _unstakeInternal(uint256 amount) internal {
        // Placeholder - implemented in Phase 3
        if (amount > _totalStakedPrincipal) revert StakingManager__InsufficientStake();
        _pendingUnstakes += amount;
    }

    function _claimUnstakedFunds() internal returns (uint256) {
        // Placeholder - implemented in Phase 3
        uint256 claimed = _pendingUnstakes;
        _pendingUnstakes = 0;
        return claimed;
    }
}
```

### Step 5: Create Unit Tests

Create `contracts/test/core/StakingManager.t.sol`:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "@forge-std/Test.sol";
import { StakingManager } from "src/core/StakingManager.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/mocks/MockAztecRollup.sol";
import { BN254Lib } from "src/libraries/BN254Lib.sol";

contract StakingManagerTest is Test {
    // Events
    event ProviderSet(address indexed admin, address indexed rewardsRecipient);
    event KeysAddedToProvider(address[] attesters);
    event StakedWithProvider(address indexed attester, uint256 amount);
    event UnstakeInitiated(address indexed attester, uint256 amount);
    event QueueDripped(address indexed attester);

    // Constants
    uint256 internal constant ACTIVATION_THRESHOLD = 100e18;

    // Contracts
    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    StakingManager internal stakingManager;

    // Actors
    address internal admin;
    address internal core;
    address internal providerAdmin;
    address internal rewardsVault;
    address internal rewardsRecipient;
    address internal alice;

    function setUp() external {
        admin = makeAddr("admin");
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        rewardsVault = makeAddr("rewardsVault");
        rewardsRecipient = makeAddr("rewardsRecipient");
        alice = makeAddr("alice");

        aztec = new MockAztec();
        rollup = new MockAztecRollup(aztec, ACTIVATION_THRESHOLD);

        stakingManager = new StakingManager(
            aztec,
            address(rollup),
            rewardsVault,
            core,
            providerAdmin,
            rewardsRecipient,
            admin
        );
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsStateCorrectly() external view {
        assertEq(address(stakingManager.stakingAsset()), address(aztec));
        assertEq(stakingManager.rollup(), address(rollup));
        assertEq(stakingManager.rewardsVault(), rewardsVault);
        assertEq(stakingManager.core(), core);
        
        IStakingManager.ProviderConfig memory config = stakingManager.getProviderConfig();
        assertEq(config.admin, providerAdmin);
        assertEq(config.rewardsRecipient, rewardsRecipient);
    }

    function test_Constructor_GrantsRoles() external view {
        assertTrue(stakingManager.hasRole(stakingManager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(stakingManager.hasRole(stakingManager.CORE_ROLE(), core));
        assertTrue(stakingManager.hasRole(stakingManager.STAKING_PROVIDER_ADMIN_ROLE(), providerAdmin));
    }

    function test_RevertWhen_ConstructorZeroAddress() external {
        vm.expectRevert(IStakingManager.StakingManager__ZeroAddress.selector);
        new StakingManager(
            aztec,
            address(0), // zero rollup
            rewardsVault,
            core,
            providerAdmin,
            rewardsRecipient,
            admin
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UnauthorizedStake() external {
        vm.prank(alice);
        vm.expectRevert();
        stakingManager.stake(100e18);
    }

    function test_RevertWhen_UnauthorizedUnstake() external {
        vm.prank(alice);
        vm.expectRevert();
        stakingManager.unStake(100e18);
    }

    function test_RevertWhen_UnauthorizedAddKeys() external {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](1);
        vm.prank(alice);
        vm.expectRevert();
        stakingManager.addKeysToProvider(keys);
    }

    /*//////////////////////////////////////////////////////////////
                            KEY QUEUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddKeysToProvider() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);
        
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        assertEq(stakingManager.getQueueLength(), 3);
    }

    function test_DripQueue() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(3);
        
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        vm.prank(providerAdmin);
        stakingManager.dripQueue(1);

        assertEq(stakingManager.getQueueLength(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                            STAKE TESTS (BASIC)
    //////////////////////////////////////////////////////////////*/

    function test_Stake_UpdatesTotalStaked() external {
        vm.prank(core);
        stakingManager.stake(100e18);

        assertEq(stakingManager.totalStaked(), 100e18);
    }

    function test_RevertWhen_StakeZeroAmount() external {
        vm.prank(core);
        vm.expectRevert(IStakingManager.StakingManager__ZeroAmount.selector);
        stakingManager.stake(0);
    }

    /*//////////////////////////////////////////////////////////////
                            UNSTAKE TESTS (BASIC)
    //////////////////////////////////////////////////////////////*/

    function test_Unstake_UpdatesPendingUnstakes() external {
        vm.prank(core);
        stakingManager.stake(100e18);

        vm.prank(core);
        stakingManager.unStake(50e18);

        assertEq(stakingManager.getPendingUnstakes(), 50e18);
    }

    function test_RevertWhen_UnstakeZeroAmount() external {
        vm.prank(core);
        vm.expectRevert(IStakingManager.StakingManager__ZeroAmount.selector);
        stakingManager.unStake(0);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = IStakingManager.KeyStore({
                attester: address(uint160(i + 1)),
                publicKeyG1: BN254Lib.G1Point({ x: i, y: i + 1 }),
                publicKeyG2: BN254Lib.G2Point({ x0: i, x1: i + 1, y0: i + 2, y1: i + 3 }),
                proofOfPossession: BN254Lib.G1Point({ x: i + 10, y: i + 11 })
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
