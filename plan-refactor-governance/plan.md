# Governance Extraction Plan

## Summary

Extract all governance transfer logic from `OllaCore` into a new `OllaGovernance` contract. Separate the treasury address from governance authority. Absorb the `TimelockController` (currently deployed separately via `DeployTimelock.s.sol`) into the governance contract itself. Make OllaCore `Ownable2Step` with OllaGovernance as its owner.

No migration concerns. There are no contracts in production. This is a clean refactor.

## Design Decisions (Confirmed)

| Decision | Choice |
|---|---|
| Approach | A: "Governance as Caller" -- all governance operations funnel through OllaGovernance |
| OllaGovernance upgradeability | UUPS upgradeable |
| Treasury storage | In OllaGovernance, independently configurable |
| Satellite address discovery | OllaGovernance reads from OllaCore (`withdrawalQueue()`, `stakingManager()`, etc.) |
| Migration | None needed -- no production contracts |
| OllaCore ownership model | `Ownable2Step` (OZ) with OllaGovernance as owner |
| TimelockController | Inherited by OllaGovernance (replaces standalone `DeployTimelock.s.sol`) |
| Test approach | Minimal refactoring, separate test files per concern |

---

## Architecture

### Before

```
Governance EOA/Multisig
    |
    v
TimelockController (standalone, deployed separately)
    |
    ├── DEFAULT_ADMIN_ROLE on OllaCore
    ├── DEFAULT_ADMIN_ROLE on WithdrawalQueue
    ├── DEFAULT_ADMIN_ROLE on RewardsVault
    ├── DEFAULT_ADMIN_ROLE on StakingManager
    ├── DEFAULT_ADMIN_ROLE on StakingProviderRegistry
    └── DEFAULT_ADMIN_ROLE on SafetyModule

OllaCore contains:
  - Parameter setters (gated by DEFAULT_ADMIN_ROLE)
  - Two-step governance transfer (proposeGovernance/acceptGovernance)
  - Satellite role propagation in acceptGovernance()
  - _modules.governance = admin address AND fee recipient
```

### After

```
Governance EOA/Multisig
    |
    v (proposer/executor/canceller)
OllaGovernance (TimelockController + UUPS + Ownable2Step)
    |
    ├── owner() of OllaCore (via Ownable2Step)
    ├── DEFAULT_ADMIN_ROLE on WithdrawalQueue
    ├── DEFAULT_ADMIN_ROLE on RewardsVault
    ├── DEFAULT_ADMIN_ROLE on StakingManager
    ├── DEFAULT_ADMIN_ROLE on StakingProviderRegistry
    └── DEFAULT_ADMIN_ROLE on SafetyModule
    |
    Stores: treasury address, governance transfer state

OllaCore contains:
  - Parameter setters (gated by onlyOwner -- which is OllaGovernance)
  - No governance transfer logic
  - Reads treasury from OllaGovernance for fee distribution
```

---

## New Contract: OllaGovernance

### Inheritance

```
OllaGovernance is
    Initializable,
    TimelockControllerUpgradeable,    (OZ 5.x upgradeable timelock)
    UUPSUpgradeable
```

**Note**: OpenZeppelin 5.x provides `TimelockControllerUpgradeable` in the upgradeable contracts package. If unavailable, wrap the non-upgradeable `TimelockController` with an initializable proxy pattern.

### State

```solidity
/// @notice The OllaCore contract this governance manages.
IOllaCore public core;

/// @notice The treasury address where fees are sent.
address public treasury;

/// @notice Pending governance address for two-step governance transfer.
address public pendingGovernance;
```

### Functions

#### Governance Transfer (two-step)

These replace the functions currently on OllaCore. The two-step transfer changes the *owner of OllaGovernance* (i.e., who can schedule timelock operations), not the governance contract address stored on OllaCore.

Wait -- actually, re-examining this: the two-step governance transfer in the current system changes which address holds admin authority over the entire protocol. In the new architecture, OllaGovernance *is* the governance contract. The question becomes: what does "governance transfer" mean when governance is a contract?

**Answer**: Governance transfer changes who controls OllaGovernance. Since OllaGovernance inherits TimelockController, "controlling" it means holding the proposer/executor roles on the timelock. The two-step transfer should:

1. Transfer the proposer/executor/canceller roles to the new governance address
2. Revoke those roles from the old governance address
3. Propagate `DEFAULT_ADMIN_ROLE` changes across satellite contracts

```solidity
function proposeGovernance(address newGovernance) external;     // timelocked
function acceptGovernance() external;                           // called by pendingGovernance
function cancelGovernanceProposal() external;                   // timelocked
```

`acceptGovernance()` is NOT timelocked -- it must be called by the pending governance address directly (same pattern as today). The proposal itself goes through the timelock.

#### Treasury Management

```solidity
function setTreasury(address newTreasury) external;    // timelocked
```

#### OllaCore Parameter Passthroughs

These call the corresponding functions on OllaCore. Since OllaGovernance is the owner of OllaCore, these calls will pass the `onlyOwner` check.

```solidity
function setProtocolFeeBP(uint256 newFeeBP) external;                   // timelocked
function setTreasuryFeeSplitBP(uint256 newSplitBP) external;            // timelocked
function setTargetBufferedAssets(uint256 newBuffer) external;            // timelocked
function setRebalanceGasThreshold(uint256 newThreshold) external;       // timelocked
function setInstantRedemptionFeeBP(uint256 newFeeBP) external;          // timelocked
function setSafetyModule(address newSafetyModule) external;             // timelocked
function recoverStAztec(address recipient, uint256 amount) external;    // timelocked
```

#### SafetyModule Parameter Passthroughs

```solidity
function setDepositCap(uint256 cap) external;                   // timelocked
function setWithdrawalMinimum(uint256 minShares) external;      // timelocked
function setMinRateDropBps(uint256 bps) external;               // timelocked
function setMaxQueueRatioBps(uint256 bps) external;             // timelocked
function setMaxAccountingDelay(uint256 delay) external;         // timelocked
```

#### Upgrade Functions

```solidity
function upgradeCore(address newImplementation) external;                        // timelocked
function upgradeSatellite(address proxy, address newImplementation) external;    // timelocked
```

#### How Timelocking Works

Since OllaGovernance inherits TimelockController, the passthrough functions are not called directly. Instead:

1. The governance admin calls `schedule()` (inherited from TimelockController) with the encoded call to the passthrough function
2. After the timelock delay, the governance admin calls `execute()` (inherited from TimelockController)
3. The TimelockController calls `this.setProtocolFeeBP(newFeeBP)` which in turn calls `core.setProtocolFeeBP(newFeeBP)`

This means the passthrough functions need to be callable by `address(this)` (the timelock calling itself). They should have a modifier like `onlyRole(EXECUTOR_ROLE)` or simply be external functions that the timelock calls via `execute()`.

**Important design choice**: The passthrough functions should NOT have their own access control. They are internal implementation that should only be reachable via the TimelockController's `execute()` flow. Since `execute()` calls `address(this).functionCall(data)`, the caller (`msg.sender`) will be `address(this)`. We gate with `require(msg.sender == address(this))` or use the `onlyRoleOrOpenRole(EXECUTOR_ROLE)` inherited modifier.

Actually, the simplest pattern: make the passthrough functions `external` and only callable by `address(this)`. This way they can only be reached through `schedule() -> execute()`.

### Initialization

```solidity
function initialize(
    uint256 minDelay,
    address[] memory proposers,
    address[] memory executors,
    address admin,
    IOllaCore core_,
    address treasury_
) external initializer;
```

---

## Changes to OllaCore

### Inheritance Change

```
// Before
OllaCore is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable, ReentrancyGuard, IOllaCore

// After
OllaCore is Initializable, Ownable2StepUpgradeable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable, ReentrancyGuard, IOllaCore
```

`Ownable2StepUpgradeable` is used instead of `Ownable2Step` because OllaCore is behind a UUPS proxy. The owner will be set to the OllaGovernance contract address during initialization.

**Note on AccessControlUpgradeable**: OllaCore still needs AccessControl for `GUARDIAN_ROLE` and `OPERATOR_ROLE`. The `DEFAULT_ADMIN_ROLE` for grant/revoke of these roles should be held by OllaGovernance (the owner). Governance transfer no longer uses `DEFAULT_ADMIN_ROLE` on OllaCore for parameter setters.

### State Changes

#### Remove

- `_pendingGovernance` -- moved to OllaGovernance
- `_modules.governance` field -- replaced by `owner()` (from Ownable2Step) for authorization and a `treasury()` view for fee distribution

#### Modify `Modules` struct

```solidity
// Before
struct Modules {
    IERC20 asset;
    IStAztec stAztec;
    IStakingManager stakingManager;
    address governance;           // <-- REMOVE
    IWithdrawalQueue withdrawalQueue;
    IRewardsVault rewardsVault;
    address safetyModule;
}

// After
struct Modules {
    IERC20 asset;
    IStAztec stAztec;
    IStakingManager stakingManager;
    IWithdrawalQueue withdrawalQueue;
    IRewardsVault rewardsVault;
    address safetyModule;
}
```

#### Add

No new state needed. `owner()` comes from Ownable2StepUpgradeable. Treasury is read from OllaGovernance dynamically.

### Function Changes

#### Remove from OllaCore

| Function | Reason |
|---|---|
| `proposeGovernance(address)` | Moved to OllaGovernance |
| `acceptGovernance()` | Moved to OllaGovernance |
| `cancelGovernanceProposal()` | Moved to OllaGovernance |
| `governance() view` | Replaced by `owner()` from Ownable2Step |
| `pendingGovernance() view` | Moved to OllaGovernance |

#### Modify Modifiers

| Function | Before | After |
|---|---|---|
| `setProtocolFeeBP` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `onlyOwner` |
| `setTreasuryFeeSplitBP` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `onlyOwner` |
| `setTargetBufferedAssets` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `onlyOwner` |
| `setRebalanceGasThreshold` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `onlyOwner` |
| `setInstantRedemptionFeeBP` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `onlyOwner` |
| `setSafetyModule` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `onlyOwner` |
| `recoverStAztec` | `onlyRole(DEFAULT_ADMIN_ROLE)` | `onlyOwner` |

#### Modify `_authorizeUpgrade`

```solidity
// Before
function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (msg.sender != _modules.governance) {
        revert OllaCore__UnauthorizedGovernance(msg.sender);
    }
    ...
}

// After
function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
    if (newImplementation == address(0)) {
        revert OllaCore__ZeroAddress("newImplementation");
    }
}
```

#### Modify Fee Distribution

In `_redeem()`:
```solidity
// Before: fee goes to _modules.governance
modules.asset.safeTransfer(modules.governance, fee);

// After: fee goes to treasury (read from OllaGovernance)
address treasuryAddr = IOllaGovernance(owner()).treasury();
modules.asset.safeTransfer(treasuryAddr, fee);
```

In `_payoutOllaProtocolFees()`:
```solidity
// Before: treasury shares minted to _modules.governance
modules.stAztec.mint(modules.governance, treasuryShares);

// After: treasury shares minted to treasury address
address treasuryAddr = IOllaGovernance(owner()).treasury();
modules.stAztec.mint(treasuryAddr, treasuryShares);
```

In `recoverStAztec()`:
```solidity
// Before: defaults to _modules.governance
address resolvedRecipient = recipient == address(0) ? _modules.governance : recipient;

// After: defaults to treasury
address resolvedRecipient = recipient == address(0) ? IOllaGovernance(owner()).treasury() : recipient;
```

#### Modify `initialize()`

```solidity
// Before: takes governance_ address, grants all roles to it
function initialize(
    IERC20 asset_,
    IStAztec stAztec_,
    IStakingManager stakingManager_,
    uint256 protocolFeeBP_,
    uint256 treasuryFeeSplitBP_,
    address governance_,
    address withdrawalQueue_,
    IRewardsVault rewardsVault_,
    address safetyModule_
) external;

// After: takes governanceContract_ address, sets it as owner, grants
// GUARDIAN_ROLE and OPERATOR_ROLE to governanceContract_ (to be re-assigned later)
function initialize(
    IERC20 asset_,
    IStAztec stAztec_,
    IStakingManager stakingManager_,
    uint256 protocolFeeBP_,
    uint256 treasuryFeeSplitBP_,
    address governanceContract_,
    address withdrawalQueue_,
    IRewardsVault rewardsVault_,
    address safetyModule_
) external;
```

Inside `initialize()`:
- Call `__Ownable2Step_init()` and `_transferOwnership(governanceContract_)` to set OllaGovernance as owner
- Remove `_grantRole(DEFAULT_ADMIN_ROLE, governance_)` -- owner() handles this
- Keep `_grantRole(GUARDIAN_ROLE, governanceContract_)` and `_grantRole(OPERATOR_ROLE, governanceContract_)` -- governance will re-assign these
- The `DEFAULT_ADMIN_ROLE` for managing GUARDIAN/OPERATOR role grants/revokes should be held by OllaGovernance. So grant `DEFAULT_ADMIN_ROLE` to governanceContract_ to allow role management.

### What Stays in OllaCore

- All vault logic (deposit, withdraw, redeem, rebalance, accounting)
- Parameter setters (now gated by `onlyOwner`)
- `GUARDIAN_ROLE` and `OPERATOR_ROLE` (via AccessControl)
- `pause()` / `unpause()` / `forceRebalanceUnpause()` (gated by `GUARDIAN_ROLE`, unchanged)
- `rebalance()` / `updateAccounting()` / `reconcileBufferedAssets()` (gated by `OPERATOR_ROLE`, unchanged)
- All view functions except `governance()` and `pendingGovernance()` (replaced by `owner()` from Ownable2Step)

---

## Changes to Satellite Contracts

### `_authorizeUpgrade` Changes

All four satellites (WithdrawalQueue, RewardsVault, StakingManager, StakingProviderRegistry) currently have a double guard:

```solidity
function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (msg.sender != IOllaCore(core).governance()) { revert ...; }
}
```

After the refactor, `IOllaCore(core).governance()` no longer exists. Two options:

**Option 1 (Recommended)**: Replace the governance check with an owner check:
```solidity
function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
    if (msg.sender != IOllaCore(core).owner()) { revert ...; }
}
```

This works because `OllaCore.owner()` returns the OllaGovernance address, which is the same address that holds `DEFAULT_ADMIN_ROLE` on all satellites. The double check is redundant but preserves the defensive pattern.

**Option 2**: Drop the governance check entirely and rely solely on `onlyRole(DEFAULT_ADMIN_ROLE)`. Simpler, but loses the belt-and-suspenders defense.

Go with **Option 1**.

### IOllaCore Interface Update

The satellites read `IOllaCore(core).governance()` in their `_authorizeUpgrade`. This needs to change:

- Add `owner()` to the `IOllaCore` interface (it comes from `Ownable2StepUpgradeable`, so it exists automatically)
- Or change satellite code to use `Ownable(core).owner()` -- but using `IOllaCore` is cleaner

Since `Ownable2StepUpgradeable` exposes a public `owner()` function, and the satellites import `IOllaCore`, add `owner()` to the IOllaCore interface.

---

## TimelockController Integration

### Current State

`DeployTimelock.s.sol` deploys a standalone `TimelockController` with configurable proposer, executor, admin, and minDelay. The governance admin wallet holds these roles and uses the timelock to call admin functions on the protocol.

### New State

OllaGovernance **inherits** `TimelockControllerUpgradeable`, so the timelock is embedded in the governance contract itself. This eliminates the need for a separate `TimelockController` deployment.

The `DeployTimelock.s.sol` script should be removed (or repurposed). Its configuration (minDelay, proposers, executors, admin) moves into `OllaGovernance.initialize()`.

### Flow

```
Governance Admin Wallet
    |
    | schedule(target=OllaGovernance, data=setProtocolFeeBP.encode(500), delay=48h)
    v
OllaGovernance (TimelockController)
    |
    | ... 48h passes ...
    |
    | execute(target=OllaGovernance, data=setProtocolFeeBP.encode(500))
    v
OllaGovernance.setProtocolFeeBP(500)
    |
    | core.setProtocolFeeBP(500)
    v
OllaCore.setProtocolFeeBP(500)  -- onlyOwner check passes (msg.sender = OllaGovernance = owner)
```

Wait -- there's a subtlety. When TimelockController calls `execute()`, it does `target.functionCall(data)`. If the target is `address(this)` (OllaGovernance calling itself), then `msg.sender` inside the passthrough function is `address(this)`. When the passthrough function then calls `core.setProtocolFeeBP(500)`, `msg.sender` for that call is OllaGovernance's address, which is `owner()` of OllaCore. This works.

But the passthrough functions on OllaGovernance need to be gated so that only the timelock can call them. Since OllaGovernance IS the timelock, the check is `msg.sender == address(this)`. Use a modifier:

```solidity
modifier onlySelf() {
    if (msg.sender != address(this)) revert OllaGovernance__OnlySelf();
    _;
}
```

Or alternatively, the `onlyRoleOrOpenRole(EXECUTOR_ROLE)` pattern from TimelockController would also work, but `onlySelf` is clearer and more restrictive.

---

## Ownable2Step for OllaCore: Rationale

Using `Ownable2StepUpgradeable` for OllaCore provides:

1. **Single owner** (OllaGovernance) for parameter setters and upgrade authorization -- replaces the `DEFAULT_ADMIN_ROLE` pattern for these functions
2. **Two-step transfer** built in -- if governance needs to change the governance contract itself (e.g., deploy OllaGovernance v2), the transfer requires acceptance by the new contract
3. **Clean separation** -- `owner()` is governance authority, `AccessControl` roles are operational (GUARDIAN, OPERATOR)
4. **Compatibility** -- `Ownable2StepUpgradeable` is standard OZ, well-audited, minimal surface area

The `DEFAULT_ADMIN_ROLE` on OllaCore is still needed for granting/revoking `GUARDIAN_ROLE` and `OPERATOR_ROLE`. OllaGovernance holds this role.

---

## Interface Changes: IOllaCore

### Remove

```solidity
function proposeGovernance(address newGovernance) external;
function acceptGovernance() external;
function cancelGovernanceProposal() external;
function governance() external view returns (address);
function pendingGovernance() external view returns (address);
```

### Remove Events

```solidity
event GovernanceProposed(address oldGovernance, address newGovernance);
event GovernanceAccepted(address oldGovernance, address newGovernance);
event GovernanceProposalCancelled(address governance, address pendingGovernance);
```

### Remove Errors

```solidity
error OllaCore__UnauthorizedGovernance(address caller);
error OllaCore__PendingGovernanceAlreadySet(address pendingGovernance);
error OllaCore__NoPendingGovernance();
error OllaCore__UnauthorizedPendingGovernance(address caller);
```

### Add

```solidity
/// @notice Returns the treasury address (reads from governance contract).
function treasury() external view returns (address);
```

The `owner()` function is automatically available from `Ownable2StepUpgradeable` and does not need to be declared in the interface, but may be added for documentation purposes.

---

## New Interface: IOllaGovernance

```solidity
interface IOllaGovernance {
    function core() external view returns (address);
    function treasury() external view returns (address);
    function pendingGovernance() external view returns (address);

    function setTreasury(address newTreasury) external;
    function proposeGovernance(address newGovernance) external;
    function acceptGovernance() external;
    function cancelGovernanceProposal() external;

    // OllaCore parameter passthroughs
    function setProtocolFeeBP(uint256 newFeeBP) external;
    function setTreasuryFeeSplitBP(uint256 newSplitBP) external;
    function setTargetBufferedAssets(uint256 newBuffer) external;
    function setRebalanceGasThreshold(uint256 newThreshold) external;
    function setInstantRedemptionFeeBP(uint256 newFeeBP) external;
    function setSafetyModule(address newSafetyModule) external;
    function recoverStAztec(address recipient, uint256 amount) external;

    // SafetyModule parameter passthroughs
    function setDepositCap(uint256 cap) external;
    function setWithdrawalMinimum(uint256 minShares) external;
    function setMinRateDropBps(uint256 bps) external;
    function setMaxQueueRatioBps(uint256 bps) external;
    function setMaxAccountingDelay(uint256 delay) external;

    // Upgrade functions
    function upgradeCore(address newImplementation) external;
    function upgradeSatellite(address proxy, address newImplementation) external;
}
```

---

## Deployment Changes

### Remove

- `DeployTimelock.s.sol` -- timelock is now embedded in OllaGovernance

### Modify

The main deployment script needs to:

1. Deploy OllaGovernance proxy with timelock configuration (minDelay, proposers, executors, admin)
2. Deploy OllaCore proxy with OllaGovernance as the governance contract / owner
3. Set OllaGovernance's `core` reference
4. Grant `DEFAULT_ADMIN_ROLE` on all satellite contracts to OllaGovernance
5. Set up GUARDIAN_ROLE and OPERATOR_ROLE on OllaCore (granted to appropriate addresses via OllaGovernance)

### Deployment Order

```
1. Deploy OllaGovernance implementation
2. Deploy OllaGovernance proxy (ERC1967) + initialize(minDelay, proposers, executors, admin, ...)
3. Deploy OllaCore implementation
4. Deploy OllaCore proxy + initialize(..., governanceContract=OllaGovernance, ...)
5. Call OllaGovernance.setCore(OllaCore)  -- or set in initialize if OllaCore address is known
6. Deploy satellite contracts (WithdrawalQueue, RewardsVault, StakingManager, StakingProviderRegistry)
   -- pass OllaGovernance address as defaultAdmin for each
7. Deploy SafetyModule with OllaGovernance as admin
8. Grant GUARDIAN_ROLE, OPERATOR_ROLE on OllaCore to appropriate addresses
```

Note: Step 5 has a chicken-and-egg issue. OllaGovernance needs to know OllaCore's address, and OllaCore's initialize needs OllaGovernance's address. Solutions:

- **Option A**: Deploy OllaGovernance first with a placeholder core address, then `setCore()` after OllaCore is deployed. OllaGovernance's `setCore()` would be a one-time setter callable only during setup (before the first operation).
- **Option B**: Deploy OllaCore first with OllaGovernance's predicted address (using CREATE2). More complex but avoids mutable setup.
- **Option C**: Deploy OllaGovernance without core reference. OllaCore sets OllaGovernance as owner during init. OllaGovernance discovers OllaCore when its passthrough functions are first called (core is passed as a parameter to `initialize()` of OllaGovernance after OllaCore is deployed).

**Recommendation**: Option A -- simplest. `setCore()` is a one-time admin function on OllaGovernance.

---

## Test Strategy

### Principle

Minimal refactoring of existing tests. Separate test files by concern.

### New Test Files

| File | Tests |
|---|---|
| `OllaGovernanceSetup.t.sol` | Base test setup with OllaGovernance deployment |
| `OllaGovernanceTransfer.t.sol` | Two-step governance transfer on OllaGovernance (replaces `OllaCoreGovernanceTransfer.t.sol`) |
| `OllaGovernanceTimelock.t.sol` | Timelock scheduling/execution for parameter changes |
| `OllaGovernanceTreasury.t.sol` | Treasury address management, fee distribution to treasury |
| `OllaGovernanceUpgrades.t.sol` | Upgrade authorization through OllaGovernance |
| `OllaGovernancePassthroughs.t.sol` | Parameter setter passthroughs (happy path + access control) |

### Modified Test Files

| File | Changes |
|---|---|
| `OllaCoreAccessControl.t.sol` | Remove governance transfer tests. Update admin function tests to use OllaGovernance as caller instead of DEFAULT_ADMIN_ROLE holder. |
| `OllaCoreGovernanceTransfer.t.sol` | Delete or rename -- functionality moved to `OllaGovernanceTransfer.t.sol` |
| `OllaCoreRebalancePause.t.sol` | Update governance-related assertions to use OllaGovernance |
| Test base/setup files | Add OllaGovernance to the deployment fixture |

### Test Coverage Requirements

- Governance transfer: propose, accept, cancel, unauthorized callers, double proposal, zero address
- Timelock: schedule, execute, cancel, insufficient delay, unauthorized proposer/executor
- Treasury: set, zero address, fee distribution (protocol fees, instant redemption fees)
- Passthroughs: each parameter setter, access control (only callable through timelock)
- Upgrades: core upgrade, satellite upgrade, unauthorized upgrade attempts
- Integration: full flow with timelock delays for parameter changes

---

## File Inventory

### New Files

| Path | Description |
|---|---|
| `contracts/src/governance/OllaGovernance.sol` | Main governance contract |
| `contracts/src/governance/IOllaGovernance.sol` | Interface for OllaGovernance |
| `contracts/test/governance/OllaGovernanceSetup.t.sol` | Test base setup |
| `contracts/test/governance/OllaGovernanceTransfer.t.sol` | Governance transfer tests |
| `contracts/test/governance/OllaGovernanceTimelock.t.sol` | Timelock tests |
| `contracts/test/governance/OllaGovernanceTreasury.t.sol` | Treasury tests |
| `contracts/test/governance/OllaGovernanceUpgrades.t.sol` | Upgrade tests |
| `contracts/test/governance/OllaGovernancePassthroughs.t.sol` | Passthrough tests |

### Modified Files

| Path | Changes |
|---|---|
| `contracts/src/core/OllaCore.sol` | Add Ownable2Step, remove governance transfer, change modifier on setters, change fee recipients |
| `contracts/src/core/interfaces/IOllaCore.sol` | Remove governance functions/events/errors, update Modules struct |
| `contracts/src/core/WithdrawalQueue.sol` | Update `_authorizeUpgrade` governance check |
| `contracts/src/core/RewardsVault.sol` | Update `_authorizeUpgrade` governance check |
| `contracts/src/staking/StakingManager.sol` | Update `_authorizeUpgrade` governance check |
| `contracts/src/staking/StakingProviderRegistry.sol` | Update `_authorizeUpgrade` governance check |
| `contracts/test/core/olla-core/OllaCoreAccessControl.t.sol` | Update for new auth model |
| `contracts/test/core/olla-core/OllaCoreGovernanceTransfer.t.sol` | Delete or move |
| `contracts/test/core/olla-core/OllaCoreRebalancePause.t.sol` | Update governance references |
| Deployment scripts | Update for OllaGovernance deployment, remove DeployTimelock.s.sol |
| `docs/overview.md` | Update architecture diagrams |
| `docs/governance-actions.md` | Update governance flow diagrams |

### Deleted Files

| Path | Reason |
|---|---|
| `contracts/script/ops/DeployTimelock.s.sol` | Timelock is embedded in OllaGovernance |
| `contracts/test/mocks/MockOllaCoreGovernance.sol` | No longer needed (if it exists for testing governance transfer on OllaCore) |

---

## Implementation Order

Execute in this order to maintain a compilable codebase at each step:

### Phase 1: Interface and Contract Skeleton
1. Create `IOllaGovernance.sol`
2. Create `OllaGovernance.sol` skeleton (compiles but not functional)
3. Update `IOllaCore.sol` -- remove governance functions, update Modules struct, add `treasury()` view

### Phase 2: OllaCore Refactor
4. Add `Ownable2StepUpgradeable` to OllaCore
5. Remove governance transfer functions from OllaCore
6. Change parameter setter modifiers to `onlyOwner`
7. Update fee distribution to use treasury from OllaGovernance
8. Update `_authorizeUpgrade`
9. Update `initialize()`

### Phase 3: Satellite Updates
10. Update `_authorizeUpgrade` in WithdrawalQueue
11. Update `_authorizeUpgrade` in RewardsVault
12. Update `_authorizeUpgrade` in StakingManager
13. Update `_authorizeUpgrade` in StakingProviderRegistry

### Phase 4: OllaGovernance Implementation
14. Implement governance transfer (propose/accept/cancel)
15. Implement treasury management
16. Implement parameter passthroughs
17. Implement upgrade functions
18. Implement TimelockController integration

### Phase 5: Deployment and Tests
19. Update deployment scripts
20. Write OllaGovernance test files
21. Update existing OllaCore test files
22. Delete obsolete files (DeployTimelock.s.sol, MockOllaCoreGovernance.sol)
23. Run full test suite and fix breakages

### Phase 6: Documentation
24. Update `docs/overview.md` (copy from `plan-refactor-governance/contracts-overview.md`)
25. Update `docs/governance-actions.md`

---

## Open Questions / Risks

1. **TimelockControllerUpgradeable availability**: Verify that OZ 5.x provides `TimelockControllerUpgradeable`. If not, a non-upgradeable `TimelockController` would need to be wrapped or OllaGovernance would compose (has-a) rather than inherit (is-a) the timelock.

2. **Self-upgrade of OllaGovernance**: Since OllaGovernance is UUPS, who authorizes its own upgrades? The timelock itself (schedule + execute an `upgradeToAndCall` on itself). The `_authorizeUpgrade` should check `msg.sender == address(this)` to ensure only the timelock can trigger self-upgrades.

3. **Governance transfer atomicity**: The `acceptGovernance()` function on OllaGovernance must atomically transfer proposer/executor/canceller roles AND propagate `DEFAULT_ADMIN_ROLE` to satellites. If any satellite call reverts, the entire transfer reverts. This is the same behavior as today's `acceptGovernance()` on OllaCore.

4. **SafetyModule role management**: SafetyModule is non-upgradeable and manages its own AccessControl. OllaGovernance needs `DEFAULT_ADMIN_ROLE` on SafetyModule to call its parameter setters. This is already the case today (timelock holds this role). The `acceptGovernance()` function should propagate `DEFAULT_ADMIN_ROLE` on SafetyModule as well.
