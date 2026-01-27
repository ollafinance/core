# Phase 1: Rewards Access Control Implementation

**Issue**: #51 - feat: Rewards access control

## Scope

From issue #51:
- Restrict updates to `_protocolFeeBP`, `_treasuryFeeSplitBP`, and recipient addresses
- Validate parameter ranges and non-zero addresses
- Emit update events for all parameter changes

## Prerequisites

- Understanding of current OllaCore fee structure
- Access to `DEFAULT_ADMIN_ROLE` (governance) for testing

## Implementation Steps

### Step 1: Update IOllaCore.sol Interface

Add new events and errors to the interface file.

**File**: `contracts/src/core/interfaces/IOllaCore.sol`

#### 1.1 Add New Events (after line 161, before ERRORS section)

```solidity
/// @notice Emitted when the protocol fee is updated.
/// @param oldFeeBP The old fee in basis points.
/// @param newFeeBP The new fee in basis points.
event ProtocolFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);

/// @notice Emitted when the treasury fee split is updated.
/// @param oldSplitBP The old split in basis points.
/// @param newSplitBP The new split in basis points.
event TreasuryFeeSplitUpdated(uint256 oldSplitBP, uint256 newSplitBP);

/// @notice Emitted when the governance address is updated.
/// @param oldGovernance The old governance address.
/// @param newGovernance The new governance address.
event GovernanceUpdated(address oldGovernance, address newGovernance);

/// @notice Emitted when the rewards vault address is updated.
/// @param oldRewardsVault The old rewards vault address.
/// @param newRewardsVault The new rewards vault address.
event RewardsVaultUpdated(address oldRewardsVault, address newRewardsVault);
```

#### 1.2 Add New Errors (after existing errors section)

```solidity
/// @notice Thrown when a fee basis points value exceeds maximum.
error OllaCore__InvalidFeeBP(uint256 feeBP);

/// @notice Thrown when a split basis points value exceeds maximum.
error OllaCore__InvalidSplitBP(uint256 splitBP);
```

#### 1.3 Add New Function Signatures (in PROVIDER ADMIN FUNCTIONS section)

```solidity
/// @notice Sets the protocol fee in basis points.
/// @param newFeeBP The new fee (0-10000).
function setProtocolFeeBP(uint256 newFeeBP) external;

/// @notice Sets the treasury fee split in basis points.
/// @param newSplitBP The new split (0-10000).
function setTreasuryFeeSplitBP(uint256 newSplitBP) external;

/// @notice Sets the governance address.
/// @param newGovernance The new governance address.
function setGovernance(address newGovernance) external;

/// @notice Sets the rewards vault address.
/// @param newRewardsVault The new rewards vault address.
function setRewardsVault(address newRewardsVault) external;
```

#### 1.4 Add View Function Signatures (in VIEW FUNCTIONS section)

```solidity
/// @notice Returns the protocol fee in basis points.
/// @return The protocol fee BP.
function protocolFeeBP() external view returns (uint256);

/// @notice Returns the treasury fee split in basis points.
/// @return The treasury fee split BP.
function treasuryFeeSplitBP() external view returns (uint256);
```

---

### Step 2: Implement Functions in OllaCore.sol

**File**: `contracts/src/core/OllaCore.sol`

#### 2.1 Add Setter Functions (after `unpause()` function, around line 268)

```solidity
/// @notice Sets the protocol fee in basis points.
/// @param newFeeBP The new fee (0-10000).
function setProtocolFeeBP(uint256 newFeeBP) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newFeeBP > BP_DIVISOR) {
        revert OllaCore__InvalidFeeBP(newFeeBP);
    }
    uint256 oldFeeBP = _protocolFeeBP;
    _protocolFeeBP = newFeeBP;
    emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);
}

/// @notice Sets the treasury fee split in basis points.
/// @param newSplitBP The new split (0-10000).
function setTreasuryFeeSplitBP(uint256 newSplitBP) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newSplitBP > BP_DIVISOR) {
        revert OllaCore__InvalidSplitBP(newSplitBP);
    }
    uint256 oldSplitBP = _treasuryFeeSplitBP;
    _treasuryFeeSplitBP = newSplitBP;
    emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);
}

/// @notice Sets the governance address.
/// @param newGovernance The new governance address.
function setGovernance(address newGovernance) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newGovernance == address(0)) {
        revert OllaCore__ZeroAddress("newGovernance");
    }
    address oldGovernance = _modules.governance;
    _modules.governance = newGovernance;
    emit GovernanceUpdated(oldGovernance, newGovernance);
}

/// @notice Sets the rewards vault address.
/// @param newRewardsVault The new rewards vault address.
function setRewardsVault(address newRewardsVault) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (newRewardsVault == address(0)) {
        revert OllaCore__ZeroAddress("newRewardsVault");
    }
    address oldRewardsVault = _modules.rewardsVault;
    _modules.rewardsVault = newRewardsVault;
    emit RewardsVaultUpdated(oldRewardsVault, newRewardsVault);
}
```

#### 2.2 Add View Functions (in EXTERNAL FUNCTIONS section, after `safetyModule()`)

```solidity
/// @notice Returns the protocol fee in basis points.
/// @return The protocol fee BP.
function protocolFeeBP() external view override returns (uint256) {
    return _protocolFeeBP;
}

/// @notice Returns the treasury fee split in basis points.
/// @return The treasury fee split BP.
function treasuryFeeSplitBP() external view override returns (uint256) {
    return _treasuryFeeSplitBP;
}
```

---

### Step 3: Add Tests

**File**: `contracts/test/core/OllaCore.t.sol`

Add a new test contract at the end of the file:

```solidity
contract OllaCoreRewardsAccessControlTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProtocolFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
    event TreasuryFeeSplitUpdated(uint256 oldSplitBP, uint256 newSplitBP);
    event GovernanceUpdated(address oldGovernance, address newGovernance);
    event RewardsVaultUpdated(address oldRewardsVault, address newRewardsVault);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant BP_DIVISOR = 10_000;
    uint256 internal constant INITIAL_PROTOCOL_FEE_BP = 500;
    uint256 internal constant INITIAL_TREASURY_SPLIT_BP = 5_000;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    address internal governance;
    address internal rewardsVault;
    MockSafetyModule internal safetyModule;
    MockWithdrawalQueue internal withdrawalQueue;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        rewardsVault = makeAddr("rewardsVault");
        safetyModule = new MockSafetyModule();
        withdrawalQueue = new MockWithdrawalQueue();
        alice = makeAddr("alice");

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            INITIAL_PROTOCOL_FEE_BP,
            INITIAL_TREASURY_SPLIT_BP,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL FEE BP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_UpdatesValue() external {
        uint256 newFeeBP = 1000;
        
        vm.prank(governance);
        vault.setProtocolFeeBP(newFeeBP);
        
        assertEq(vault.protocolFeeBP(), newFeeBP, "protocol fee updated");
    }

    function test_SetProtocolFeeBP_EmitsEvent() external {
        uint256 newFeeBP = 1000;
        
        vm.expectEmit(true, true, true, true, address(vault));
        emit ProtocolFeeUpdated(INITIAL_PROTOCOL_FEE_BP, newFeeBP);
        
        vm.prank(governance);
        vault.setProtocolFeeBP(newFeeBP);
    }

    function test_SetProtocolFeeBP_AllowsZero() external {
        vm.prank(governance);
        vault.setProtocolFeeBP(0);
        
        assertEq(vault.protocolFeeBP(), 0, "protocol fee set to zero");
    }

    function test_SetProtocolFeeBP_AllowsMax() external {
        vm.prank(governance);
        vault.setProtocolFeeBP(BP_DIVISOR);
        
        assertEq(vault.protocolFeeBP(), BP_DIVISOR, "protocol fee set to max");
    }

    function test_RevertWhen_SetProtocolFeeBP_Unauthorized() external {
        vm.expectRevert();
        vm.prank(alice);
        vault.setProtocolFeeBP(1000);
    }

    function test_RevertWhen_SetProtocolFeeBP_ExceedsMax() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, BP_DIVISOR + 1));
        vm.prank(governance);
        vault.setProtocolFeeBP(BP_DIVISOR + 1);
    }

    /*//////////////////////////////////////////////////////////////
                      TREASURY FEE SPLIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetTreasuryFeeSplitBP_UpdatesValue() external {
        uint256 newSplitBP = 7500;
        
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(newSplitBP);
        
        assertEq(vault.treasuryFeeSplitBP(), newSplitBP, "treasury split updated");
    }

    function test_SetTreasuryFeeSplitBP_EmitsEvent() external {
        uint256 newSplitBP = 7500;
        
        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryFeeSplitUpdated(INITIAL_TREASURY_SPLIT_BP, newSplitBP);
        
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(newSplitBP);
    }

    function test_SetTreasuryFeeSplitBP_AllowsZero() external {
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(0);
        
        assertEq(vault.treasuryFeeSplitBP(), 0, "treasury split set to zero");
    }

    function test_SetTreasuryFeeSplitBP_AllowsMax() external {
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(BP_DIVISOR);
        
        assertEq(vault.treasuryFeeSplitBP(), BP_DIVISOR, "treasury split set to max");
    }

    function test_RevertWhen_SetTreasuryFeeSplitBP_Unauthorized() external {
        vm.expectRevert();
        vm.prank(alice);
        vault.setTreasuryFeeSplitBP(7500);
    }

    function test_RevertWhen_SetTreasuryFeeSplitBP_ExceedsMax() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, BP_DIVISOR + 1));
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(BP_DIVISOR + 1);
    }

    /*//////////////////////////////////////////////////////////////
                         GOVERNANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetGovernance_UpdatesValue() external {
        address newGovernance = makeAddr("newGovernance");
        
        vm.prank(governance);
        vault.setGovernance(newGovernance);
        
        assertEq(vault.governance(), newGovernance, "governance updated");
    }

    function test_SetGovernance_EmitsEvent() external {
        address newGovernance = makeAddr("newGovernance");
        
        vm.expectEmit(true, true, true, true, address(vault));
        emit GovernanceUpdated(governance, newGovernance);
        
        vm.prank(governance);
        vault.setGovernance(newGovernance);
    }

    function test_RevertWhen_SetGovernance_Unauthorized() external {
        address newGovernance = makeAddr("newGovernance");
        
        vm.expectRevert();
        vm.prank(alice);
        vault.setGovernance(newGovernance);
    }

    function test_RevertWhen_SetGovernance_ZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newGovernance"));
        vm.prank(governance);
        vault.setGovernance(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        REWARDS VAULT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetRewardsVault_UpdatesValue() external {
        address newRewardsVault = makeAddr("newRewardsVault");
        
        vm.prank(governance);
        vault.setRewardsVault(newRewardsVault);
        
        assertEq(vault.rewardsVault(), newRewardsVault, "rewards vault updated");
    }

    function test_SetRewardsVault_EmitsEvent() external {
        address newRewardsVault = makeAddr("newRewardsVault");
        
        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsVaultUpdated(rewardsVault, newRewardsVault);
        
        vm.prank(governance);
        vault.setRewardsVault(newRewardsVault);
    }

    function test_RevertWhen_SetRewardsVault_Unauthorized() external {
        address newRewardsVault = makeAddr("newRewardsVault");
        
        vm.expectRevert();
        vm.prank(alice);
        vault.setRewardsVault(newRewardsVault);
    }

    function test_RevertWhen_SetRewardsVault_ZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newRewardsVault"));
        vm.prank(governance);
        vault.setRewardsVault(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProtocolFeeBP_ReturnsInitialValue() external view {
        assertEq(vault.protocolFeeBP(), INITIAL_PROTOCOL_FEE_BP, "initial protocol fee");
    }

    function test_TreasuryFeeSplitBP_ReturnsInitialValue() external view {
        assertEq(vault.treasuryFeeSplitBP(), INITIAL_TREASURY_SPLIT_BP, "initial treasury split");
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetProtocolFeeBP_ValidRange(uint256 feeBP) external {
        feeBP = bound(feeBP, 0, BP_DIVISOR);
        
        vm.prank(governance);
        vault.setProtocolFeeBP(feeBP);
        
        assertEq(vault.protocolFeeBP(), feeBP, "fuzz protocol fee");
    }

    function testFuzz_SetTreasuryFeeSplitBP_ValidRange(uint256 splitBP) external {
        splitBP = bound(splitBP, 0, BP_DIVISOR);
        
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(splitBP);
        
        assertEq(vault.treasuryFeeSplitBP(), splitBP, "fuzz treasury split");
    }

    function testFuzz_SetProtocolFeeBP_InvalidRange(uint256 feeBP) external {
        feeBP = bound(feeBP, BP_DIVISOR + 1, type(uint256).max);
        
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, feeBP));
        vm.prank(governance);
        vault.setProtocolFeeBP(feeBP);
    }

    function testFuzz_SetTreasuryFeeSplitBP_InvalidRange(uint256 splitBP) external {
        splitBP = bound(splitBP, BP_DIVISOR + 1, type(uint256).max);
        
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, splitBP));
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(splitBP);
    }
}
```

---

## Test Cases from Issue

| Test Requirement | Test Name | Status |
|-----------------|-----------|--------|
| Unauthorized updates revert | `test_RevertWhen_SetProtocolFeeBP_Unauthorized` | ✅ |
| Unauthorized updates revert | `test_RevertWhen_SetTreasuryFeeSplitBP_Unauthorized` | ✅ |
| Unauthorized updates revert | `test_RevertWhen_SetGovernance_Unauthorized` | ✅ |
| Unauthorized updates revert | `test_RevertWhen_SetRewardsVault_Unauthorized` | ✅ |
| Invalid values revert | `test_RevertWhen_SetProtocolFeeBP_ExceedsMax` | ✅ |
| Invalid values revert | `test_RevertWhen_SetTreasuryFeeSplitBP_ExceedsMax` | ✅ |
| Invalid values revert | `test_RevertWhen_SetGovernance_ZeroAddress` | ✅ |
| Invalid values revert | `test_RevertWhen_SetRewardsVault_ZeroAddress` | ✅ |
| Update events include old/new values | `test_SetProtocolFeeBP_EmitsEvent` | ✅ |
| Update events include old/new values | `test_SetTreasuryFeeSplitBP_EmitsEvent` | ✅ |
| Update events include old/new values | `test_SetGovernance_EmitsEvent` | ✅ |
| Update events include old/new values | `test_SetRewardsVault_EmitsEvent` | ✅ |

---

## Acceptance Criteria

| Criteria | Implementation |
|----------|---------------|
| All privileged configuration is permissioned | `onlyRole(DEFAULT_ADMIN_ROLE)` modifier on all setters |
| All privileged configuration is observable | Events with old/new values for all parameters |

---

## Verification

```bash
# Run all tests
forge test --match-contract OllaCoreRewardsAccessControlTest -vvv

# Run specific test categories
forge test --match-test "test.*ProtocolFeeBP" -vvv
forge test --match-test "test.*TreasuryFeeSplitBP" -vvv
forge test --match-test "test.*Governance" -vvv
forge test --match-test "test.*RewardsVault" -vvv

# Run fuzz tests
forge test --match-test "testFuzz" -vvv

# Check coverage
forge coverage --match-contract OllaCore

# Build to verify compilation
forge build
```

---

## Implementation Notes

1. **Role Selection**: `DEFAULT_ADMIN_ROLE` is used for all setters since these are critical governance parameters that affect protocol economics.

2. **Validation Strategy**:
   - Fee BP values: Must be ≤ 10000 (100%)
   - Address values: Must not be zero address

3. **Event Design**: All events include both old and new values for transparency and off-chain tracking.

4. **No Additional Storage**: Implementation uses existing storage slots (`_protocolFeeBP`, `_treasuryFeeSplitBP`, `_modules.governance`, `_modules.rewardsVault`).

5. **Upgrade Safety**: No changes to storage layout, so upgrade-safe.
