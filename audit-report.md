# Olla Core Protocol — Trail of Bits Skills Security Audit Report

**Date:** 2026-02-17
**Protocol:** Olla Core — Liquid Staking for Aztec
**Scope:** All production Solidity contracts in `contracts/src/` (~3,774 lines across 7 contracts)
**Methodology:** Trail of Bits Claude Code Skills Marketplace (9 skills applied)
**Solidity Version:** 0.8.27 (Cancun EVM, via_ir enabled)
**Dependencies:** OpenZeppelin 5.5.0, Aztec Contracts 3.0.1

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Skills Applied](#2-skills-applied)
3. [Protocol Architecture](#3-protocol-architecture)
4. [Consolidated Findings](#4-consolidated-findings)
   - [4.1 HIGH Severity](#41-high-severity)
   - [4.2 MEDIUM Severity](#42-medium-severity)
   - [4.3 LOW Severity](#43-low-severity)
   - [4.4 INFORMATIONAL](#44-informational)
5. [Trust Assumptions Compliance](#5-trust-assumptions-compliance)
6. [Internal Audit Fix Verification](#6-internal-audit-fix-verification)
7. [Code Maturity Assessment](#7-code-maturity-assessment)
8. [Entry Point Analysis](#8-entry-point-analysis)
9. [Variant Analysis](#9-variant-analysis)
10. [Missing Invariant Tests](#10-missing-invariant-tests)
11. [Differential Review of Recent Fixes](#11-differential-review-of-recent-fixes)
12. [DeFi-Specific Risks](#12-defi-specific-risks)
13. [Positive Security Properties](#13-positive-security-properties)
14. [Recommendations](#14-recommendations)

---

## 1. Executive Summary

Olla Core is a liquid staking protocol for the Aztec network. Users deposit AZTEC tokens and receive stAztec (an ERC-20 liquid staking derivative). The protocol delegates staked tokens to Aztec rollup attesters and distributes rewards via an exchange rate mechanism.

This report consolidates findings from 9 Trail of Bits security analysis skills run against the full codebase. The analysis identified **4 HIGH**, **15 MEDIUM**, **16 LOW**, and **12+ INFORMATIONAL** findings across access control, configuration safety, state machine correctness, token integration, and DeFi-specific risk categories.

The codebase demonstrates mature engineering practices: role-based access control, consistent reentrancy protection, gas-bounded computation, circuit breakers, comprehensive testing (55 test files, 28 invariant tests), and zero Slither findings. Recent security fixes (first-depositor attack mitigation, rebalance deadlock resolution) were verified as correctly implemented.

The most critical areas requiring attention before mainnet are: (1) implementing two-step governance transfer, (2) adding slippage protection on deposits/redemptions, (3) bounding SafetyModule configuration parameters, (4) adding underflow protection in `totalAssets()`, and (5) implementing a timelock on governance actions.

---

## 2. Skills Applied

| #   | Skill                         | Purpose                                                            | Findings                                  |
| --- | ----------------------------- | ------------------------------------------------------------------ | ----------------------------------------- |
| 1   | **Entry Point Analyzer**      | Map all state-changing functions, access control, external calls   | 48 functions, 7 findings                  |
| 2   | **Sharp Edges**               | Identify footgun APIs, silent failures, dangerous defaults         | 20 findings                               |
| 3   | **Insecure Defaults**         | Scan for hardcoded values, fail-open patterns, weak initialization | 12 findings                               |
| 4   | **Audit Context Building**    | Deep architectural analysis, trust boundaries, invariant mapping   | 15 assumptions documented                 |
| 5   | **Spec-to-Code Compliance**   | Validate trust-assumptions.md and verify all 10 audit fixes        | 8 trust assumptions, 10 fix verifications |
| 6   | **Variant Analysis**          | Generalize 8 known vulnerability patterns across the codebase      | 15 variants found                         |
| 7   | **Property-Based Testing**    | Catalog existing invariants, identify missing critical properties  | 28 existing, 12 missing                   |
| 8   | **Building Secure Contracts** | Token analysis, code maturity scoring, DeFi risk assessment        | Maturity: 3.33/4                          |
| 9   | **Differential Review**       | Review 5 recent security fix commits for correctness               | All 5 verified correct                    |

---

## 3. Protocol Architecture

### 3.1 Contract Map

| Contract                    | Lines | Upgradeability  | Role                                                                      |
| --------------------------- | ----- | --------------- | ------------------------------------------------------------------------- |
| **OllaCore**                | 1,821 | UUPS Proxy      | Central vault: deposits, withdrawals, rebalance state machine, accounting |
| **StAztec**                 | 83    | Non-upgradeable | ERC-20 + ERC-2612 Permit liquid staking receipt token                     |
| **WithdrawalQueue**         | 242   | UUPS Proxy      | FIFO queue for async withdrawal requests                                  |
| **RewardsVault**            | 136   | UUPS Proxy      | Holds staking rewards; delta-based recording                              |
| **StakingManager**          | 1,001 | UUPS Proxy      | Manages attester staking/unstaking on Aztec rollup                        |
| **StakingProviderRegistry** | 214   | UUPS Proxy      | Manages attester BLS key queue                                            |
| **SafetyModule**            | 277   | Non-upgradeable | Circuit breaker and deposit cap enforcement                               |

### 3.2 Role Hierarchy

| Role                          | Holder            | Capabilities                                        |
| ----------------------------- | ----------------- | --------------------------------------------------- |
| `DEFAULT_ADMIN_ROLE`          | Governance        | Upgrades, fee config, module swaps, role management |
| `GUARDIAN_ROLE`               | Guardian multisig | Pause/unpause, force rebalance unpause              |
| `OPERATOR_ROLE`               | Protocol bot      | Rebalance, accounting updates                       |
| `MINTER_ROLE`                 | OllaCore only     | Mint stAztec                                        |
| `BURNER_ROLE`                 | OllaCore only     | Burn stAztec (bypasses allowance)                   |
| `STAKING_PROVIDER_ADMIN_ROLE` | Staking provider  | Manage attester BLS keys                            |

### 3.3 Trust Boundary Map

```
UNTRUSTED                    TRUST BOUNDARY                 TRUSTED
=========                    ==============                 =======

End Users  ---> [nonReentrant + pause] ---> OllaCore
                                               |
                                               +--- [MINTER/BURNER_ROLE] ---> StAztec
                                               +--- [onlyCore] ------------> WithdrawalQueue
                                               +--- [onlyCore] ------------> RewardsVault
                                               +--- [onlyCore] ------------> SafetyModule
                                               +--- [onlyCore] ------------> StakingManager
                                                                                |
                                                                                +--- [onlyStakingManager] --> StakingProviderRegistry
                                                                                +--- [TRUST: T-7] ---------> Aztec Rollup (EXTERNAL)
```

### 3.4 Key Invariants

```
totalAssets = bufferedAssets + stakedPrincipal + rewardsVaultBalance + claimableRewards - slashingDelta
exchangeRate = (totalAssets + 1) * 1e18 / (stAztec.totalSupply + 1)
asset.balanceOf(OllaCore) >= bufferedAssets + _finalizedUnclaimedAssets
slashingDelta is monotonically non-decreasing
rebalance steps only advance forward: Done -> Harvest -> ... -> Done
```

---

## 4. Consolidated Findings

### 4.1 HIGH Severity

#### H-01: `setGovernance` Is Atomic and Irreversible — No Two-Step Transfer

**Source:** Sharp Edges (SE-04)
**Location:** `OllaCore.sol:387-415`

`setGovernance()` atomically transfers `DEFAULT_ADMIN_ROLE`, `GUARDIAN_ROLE`, and `OPERATOR_ROLE` to the new address and revokes them from the old one. This is a complete, immediate, irreversible transfer of all protocol authority in a single transaction with no timelock, no two-step confirmation, and no recovery mechanism.

```solidity
function setGovernance(address newGovernance) external override onlyRole(DEFAULT_ADMIN_ROLE) ... {
    _grantRole(AccessControlUpgradeable.DEFAULT_ADMIN_ROLE, newGovernance);
    _grantRole(GUARDIAN_ROLE, newGovernance);
    _grantRole(OPERATOR_ROLE, newGovernance);
    if (oldGovernance != address(0)) {
        _revokeRole(DEFAULT_ADMIN_ROLE, oldGovernance);
        _revokeRole(GUARDIAN_ROLE, oldGovernance);
        _revokeRole(OPERATOR_ROLE, oldGovernance);
    }
}
```

A typo in the governance address or a compromised key irrevocably locks out all protocol governance.

**Recommendation:** Implement a two-step governance transfer: `proposeGovernance(address)` + `acceptGovernance()` (must be called by the proposed address). Add a timelock delay.

---

#### H-02: `StAztec.burn()` Bypasses Allowance — God-Mode BURNER_ROLE

**Source:** Entry Point Analyzer (F-06), Sharp Edges (SE-01), Building Secure Contracts (H-2)
**Location:** `StAztec.sol:63-65`

The `burn(address from, uint256 amount)` function bypasses ERC-20 allowance checks entirely. Any holder of `BURNER_ROLE` can burn arbitrary amounts of any user's tokens without approval. Currently only OllaCore holds this role, but `DEFAULT_ADMIN_ROLE` can grant it to additional addresses via OpenZeppelin's `AccessControl.grantRole()`.

```solidity
function burn(address from, uint256 amount) external override onlyRole(BURNER_ROLE) {
    _burn(from, amount);
}
```

**Recommendation:** Consider requiring `msg.sender == from || allowance(from, msg.sender) >= amount` for non-OllaCore callers, or lock the BURNER_ROLE admin to prevent additional grants.

---

#### H-03: `totalAssets()` Can Underflow via `slashingDelta` — DoS on All Core Functions

**Source:** Sharp Edges (SE-05)
**Location:** `OllaCore.sol:914-918`

```solidity
return buckets.bufferedAssets + buckets.stakedPrincipal + buckets.rewardsVaultBalance
    + buckets.claimableRewards - buckets.slashingDelta;
```

If `slashingDelta` exceeds the sum of the other four fields, this reverts with an arithmetic underflow. This would DoS every function that calls `totalAssets()`: `deposit`, `requestRedeem`, `redeem`, `rebalance`, `updateAccounting`, `exchangeRate`, `convertToShares`, and `convertToAssets`.

**Recommendation:** Add a floor: `return slashingDelta >= total ? 0 : total - slashingDelta`.

---

#### H-04: Rebalance Pause Can Lock All User Operations Indefinitely

**Source:** Sharp Edges (SE-19), Building Secure Contracts (H-1)
**Location:** `OllaCore.sol:493-711, 341-349`

The rebalance state machine sets `_rebalancePaused = true` at cycle start, blocking all deposits and withdrawals. If the operator is unavailable, sends insufficient gas, or the Aztec rollup is unresponsive, users are locked out indefinitely. The guardian's `forceRebalanceUnpause()` requires `step == Done`, so it cannot help during an in-progress rebalance.

**Recommendation:** Add a `forceRebalanceReset` function gated to `DEFAULT_ADMIN_ROLE` that resets the state machine to `Done`, or add a time-based emergency unpause.

---

### 4.2 MEDIUM Severity

#### M-01: No Slippage Protection on Deposit or Instant Redemption

**Source:** Building Secure Contracts (M-1)
**Location:** `OllaCore.sol:203-213, 289-299`

Users cannot specify minimum shares out (deposit) or minimum assets out (redeem). While the rebalance pause provides structural protection against sandwich attacks during accounting updates, standalone `updateAccounting()` calls could still be sandwiched.

**Recommendation:** Add `minSharesOut` parameter to `deposit()` and `minAssetsOut` parameter to `redeem()`.

---

#### M-02: Protocol Fee and Instant Redemption Fee Accept 0–100%

**Source:** Insecure Defaults (Finding 1, 3), Sharp Edges (SE-02), Building Secure Contracts (M-2)
**Location:** `OllaCore.sol:353-366, 466-479`

All fee parameters are validated with `newFeeBP > BP_DIVISOR` only, allowing any value from 0 to 10,000 (100%). Setting `instantRedemptionFeeBP = 10000` confiscates the entire redemption as fee. Setting `protocolFeeBP = 10000` takes all rewards.

**Recommendation:** Impose hardcoded maximum fee caps (e.g., `MAX_PROTOCOL_FEE_BP = 5000`, `MAX_INSTANT_REDEMPTION_FEE_BP = 2000`).

---

#### M-03: SafetyModule Circuit Breaker Thresholds Accept Extreme Values

**Source:** Insecure Defaults (Finding 5), Sharp Edges (SE-06), Variant Analysis (V-6.4, V-6.5)
**Location:** `SafetyModule.sol:86-121, 183-209`

All SafetyModule setters (`setMinRateDropBps`, `setMaxQueueRatioBps`, `setMaxAccountingDelay`, `setDepositCap`) accept arbitrary `uint256` values with no validation:

- `minRateDropBps = 0`: ANY rate decrease triggers breaker, DoS-ing the protocol
- `maxAccountingDelay = 0`: accounting is always stale, bricking the rebalance flow
- `minRateDropBps > 10000`: circuit breaker NEVER fires, defeating its purpose
- `maxAccountingDelay = type(uint256).max`: disables staleness checks entirely

**Recommendation:** Add bounds validation:

- `minRateDropBps`: between 1 and 5000
- `maxQueueRatioBps`: between 100 and 9000
- `maxAccountingDelay`: between 1 hour and 7 days
- `depositCap`: must be > 0

---

#### M-04: `targetBufferedAssets` Defaults to 0 — No Withdrawal Liquidity Buffer

**Source:** Insecure Defaults (Finding 4)
**Location:** `OllaCore.sol:181`

During initialization, `targetBufferedAssets` is explicitly set to 0. This means the rebalance logic attempts to stake ALL buffered assets, leaving zero liquid assets for instant redemptions or withdrawal finalization.

**Recommendation:** Set a meaningful default buffer (e.g., 5-10% of deposits) or require governance to explicitly set it post-deployment.

---

#### M-05: Rebalance Gas Threshold Has No Bounds

**Source:** Insecure Defaults (Finding 7), Sharp Edges (SE-03)
**Location:** `OllaCore.sol:451-462`

`setRebalanceGasThreshold()` accepts any `uint256` value. Setting to `type(uint256).max` permanently deadlocks the rebalance. Setting to 0 fails at StakingManager (asymmetric validation). OllaCore also has a different initial default (180,000) than StakingManager (50,000).

**Recommendation:** Enforce bounds (e.g., 20,000 to 1,000,000). Add zero-check in OllaCore to match StakingManager.

---

#### M-06: Inconsistent UUPS Upgrade Authorization

**Source:** Entry Point Analyzer (F-02), Variant Analysis (V-8.1)
**Location:** `WithdrawalQueue.sol:237-241`, `RewardsVault.sol:131-135` vs `OllaCore.sol:1731-1738`

| Contract                | `_authorizeUpgrade` Check                                   |
| ----------------------- | ----------------------------------------------------------- |
| OllaCore                | `onlyRole(DEFAULT_ADMIN_ROLE)` + `msg.sender == governance` |
| StakingManager          | `onlyRole(DEFAULT_ADMIN_ROLE)` + `msg.sender == governance` |
| StakingProviderRegistry | `onlyRole(DEFAULT_ADMIN_ROLE)` + `msg.sender == governance` |
| **WithdrawalQueue**     | `onlyRole(DEFAULT_ADMIN_ROLE)` only                         |
| **RewardsVault**        | `onlyRole(DEFAULT_ADMIN_ROLE)` only                         |

If `DEFAULT_ADMIN_ROLE` is granted to a non-governance address, that address could upgrade WithdrawalQueue and RewardsVault but not the other three.

**Recommendation:** Add governance body check to WithdrawalQueue and RewardsVault `_authorizeUpgrade` for consistency.

---

#### M-07: No Timelock on Governance Actions

**Source:** Building Secure Contracts (M-4)
**Location:** Multiple

Upgrades, fee changes, governance transfer, and rewards vault replacement all take effect immediately. No delay for users to react.

**Recommendation:** Implement a timelock for sensitive governance operations.

---

#### M-08: Governance Address Divergence Across Contracts

**Source:** Sharp Edges (SE-20), Building Secure Contracts (M-5)
**Location:** `OllaCore.sol:387-415`, `StakingManager.sol:51,178`

OllaCore's governance is mutable via `setGovernance()`, but StakingManager and StakingProviderRegistry store their own `governance` addresses set once during initialization with no setter. After a governance migration, these contracts still reference the old governance for upgrade authorization.

**Recommendation:** Add `setGovernance` functions to StakingManager and StakingProviderRegistry, or propagate changes from OllaCore.

---

#### M-09: Treasury Fee Split Can Direct 100% to One Party

**Source:** Insecure Defaults (Finding 2)
**Location:** `OllaCore.sol:370-383`

`setTreasuryFeeSplitBP()` allows values from 0 to 10,000. Setting to 0 directs all fees to the staking provider. Setting to 10,000 directs 100% to treasury.

**Recommendation:** Consider enforcing minimum splits for both parties.

---

#### M-10: `StakingManager.computeAttesterState()` Missing Reentrancy Guard

**Source:** Entry Point Analyzer (F-01)
**Location:** `StakingManager.sol:240`

`computeAttesterState()` is callable directly by `OPERATOR_ROLE` (not routed through OllaCore's `nonReentrant` context) and makes external calls to `rollup.getAttesterView()` in a loop, yet has no `nonReentrant` modifier. It modifies `_cachedState`, `_accumulator`, and attester statuses.

**Recommendation:** Add `nonReentrant` modifier.

---

#### M-11: Withdrawal Queue Head-of-Line Blocking

**Source:** Sharp Edges (SE-10), Building Secure Contracts (M-3)
**Location:** `WithdrawalQueue.sol:146-184`

The FIFO finalization loop breaks (does not skip) when it encounters a request exceeding available liquidity. A single large withdrawal request blocks all subsequent requests. Documented as intentional but exploitable for griefing.

**Recommendation:** Consider partial finalization, a maximum request size, or skip-ahead for requests below a threshold.

---

#### M-12: `setAttesterStateMaxAge` Controllable by OPERATOR_ROLE Without Bounds

**Source:** Sharp Edges (SE-15)
**Location:** `StakingManager.sol:282-289`

A compromised operator can set `maxAge = type(uint256).max` (disabling staleness checks) or `maxAge = 1` (DoS). This parameter has outsized security impact for an OPERATOR-level function.

**Recommendation:** Move to `DEFAULT_ADMIN_ROLE` and add bounds (e.g., 1 hour to 48 hours).

---

#### M-13: `setMaxAccountingDelay(0)` Bricks the Rebalance Flow

**Source:** Variant Analysis (V-6.5)
**Location:** `SafetyModule.sol:207-209`

Setting `maxAccountingDelay = 0` causes `checkAccountingLiveness()` to trigger the circuit breaker on every block, as `block.timestamp > lastAccountingTimestamp` is always true.

**Recommendation:** Add `if (maxAccountingDelay_ == 0) revert SafetyModule__InvalidParameter()`.

---

#### M-14: Rebalance Griefable by Low-Gas Operator Calls

**Source:** Sharp Edges (SE-19)
**Location:** `OllaCore.sol:493-711`

A malicious operator can call `rebalance()` with just enough gas to enter the Harvest step (pausing the protocol) but not enough to make progress. The `forceRebalanceUnpause` cannot help because the step is not `Done`.

**Recommendation:** Add a minimum gas requirement check at the start of `rebalance()`.

---

#### M-15: `depositCap = 0` Silently Blocks All Deposits

**Source:** Sharp Edges (SE-07), Variant Analysis (V-6.3)
**Location:** `SafetyModule.sol:106, 246-257`

Setting `depositCap = 0` could be intended as "no cap" but actually means "cap at zero." Users get a confusing `DepositCapExceeded` error.

**Recommendation:** Use `type(uint256).max` as sentinel for "no cap." Validate `cap > 0` in setter.

---

### 4.3 LOW Severity

#### L-01: `withdrawalMinimum` Hardcoded to 0 — Dust Withdrawal Attacks

**Source:** Insecure Defaults (Finding 6)
**Location:** `SafetyModule.sol:106`

Users can submit withdrawal requests for dust amounts (1 wei), griefing the FIFO queue with storage-consuming requests.

**Recommendation:** Set a non-trivial default withdrawal minimum.

---

#### L-02: Protocol Initializes as Unpaused — Active Immediately

**Source:** Insecure Defaults (Finding 8)
**Location:** `OllaCore.sol:144-197`

The protocol accepts operations immediately after initialization, before governance has verified module connections or set appropriate parameters.

**Recommendation:** Initialize in a paused state; require explicit unpause by governance.

---

#### L-03: Governance Receives ALL Three Roles at Initialization

**Source:** Insecure Defaults (Finding 9)
**Location:** `OllaCore.sol:194-196`

A single governance address gets `DEFAULT_ADMIN_ROLE`, `GUARDIAN_ROLE`, and `OPERATOR_ROLE`. No separation of duties.

**Recommendation:** Document expectation of post-deployment role separation. Consider requiring separate addresses.

---

#### L-04: `SafetyModule.setWithdrawalMinimum` Has No Upper Bound

**Source:** Entry Point Analyzer (F-03)
**Location:** `SafetyModule.sol:189`

Admin could set `withdrawalMinimum = type(uint256).max`, blocking all withdrawals.

**Recommendation:** Add reasonable upper bound.

---

#### L-05: `claimRequestById` Callable by Anyone

**Source:** Entry Point Analyzer (F-04), Sharp Edges (SE-08), Variant Analysis (V-1.1)
**Location:** `OllaCore.sol:279`

Any address can trigger claim execution for any finalized withdrawal request. Funds go to the recorded recipient, so no theft is possible, but users cannot delay their own claims.

**Recommendation:** Add `msg.sender == owner || msg.sender == recipient` check, or document as intentional.

---

#### L-06: `WithdrawalQueue.requestWithdrawal` Missing Defense-in-Depth Reentrancy Guard

**Source:** Entry Point Analyzer (F-05)
**Location:** `WithdrawalQueue.sol:104`

No `nonReentrant` modifier. Currently safe because it's only callable from OllaCore's `nonReentrant` context, but defense-in-depth suggests adding the guard.

**Recommendation:** Add `nonReentrant` modifier.

---

#### L-07: Redundant `onlyCore` on Internal `_initiateUnstakeRequests`

**Source:** Variant Analysis (V-5.1)
**Location:** `StakingManager.sol:588`

The `internal` function has `onlyCore` modifier, but its caller `unstake()` already has `onlyCore`. Wastes gas.

**Recommendation:** Remove the redundant modifier.

---

#### L-08: `requestRedeem` Missing Early Zero-Shares Check

**Source:** Variant Analysis (V-6.1)
**Location:** `OllaCore.sol:1186-1211`

Does not check `shares == 0` at the top. Relies on downstream `WithdrawalQueue.requestWithdrawal` to reject. Wastes gas and is inconsistent with `_deposit` and `_redeem`.

**Recommendation:** Add `if (shares == 0) revert OllaCore__InvalidAmount()`.

---

#### L-09: `setRebalanceGasThreshold(0)` Asymmetric Validation

**Source:** Variant Analysis (V-6.2)
**Location:** `OllaCore.sol:451-462`

OllaCore accepts 0 but StakingManager rejects it. Transaction reverts at StakingManager with a confusing error.

**Recommendation:** Add zero-check in OllaCore for consistency.

---

#### L-10: `_removeOwnerRequest` Silently Returns on Missing Index

**Source:** Sharp Edges (SE-09)
**Location:** `OllaCore.sol:1325-1343`

When `_ownerRequestIndex[requestId] == 0`, the function silently does nothing instead of reverting. Masks potential inconsistencies.

**Recommendation:** Replace with `revert` for immediate visibility of inconsistencies.

---

#### L-11: Stringly-Typed Circuit Breaker Reasons

**Source:** Sharp Edges (SE-11)
**Location:** `SafetyModule.sol:21-27`

Uses `keccak256("RATE_DROP")` etc. A typo in a future breaker reason would silently compile but break off-chain monitoring.

**Recommendation:** Use an `enum` for type safety.

---

#### L-12: WithdrawalQueue `_FINALIZE_GAS_THRESHOLD` Not Configurable

**Source:** Insecure Defaults (Finding 12), Sharp Edges (SE-12)
**Location:** `WithdrawalQueue.sol:30`

Hardcoded constant `50,000`. Unlike OllaCore's configurable threshold, this requires a proxy upgrade to change.

**Recommendation:** Make configurable via governance setter, or document the upgrade requirement.

---

#### L-13: `__UUPSUpgradeable_init()` Not Called

**Source:** Building Secure Contracts (L-1)
**Location:** All 5 upgradeable contracts

While a no-op in OZ 5.x, best practice for forward-compatibility.

**Recommendation:** Add the init call.

---

#### L-14: Non-Upgradeable `ReentrancyGuard` in UUPS Proxies

**Source:** Spec-to-Code Compliance (S-2 verification), Building Secure Contracts (L-3)
**Location:** All 5 upgradeable contracts

All upgradeable contracts import non-upgradeable `ReentrancyGuard`. Works correctly on Cancun EVM with ERC-7201 namespaced storage, but architecturally inconsistent. External auditors will flag this.

**Recommendation:** Switch to `ReentrancyGuardUpgradeable` or document the design choice.

---

#### L-15: `minRateDropBps = 0` Makes Breaker Maximally Sensitive

**Source:** Variant Analysis (V-6.4)
**Location:** `SafetyModule.sol:195-198`

Zero could be expected to mean "disabled" but actually triggers the breaker on any 1-wei rate decrease.

**Recommendation:** Document or validate.

---

#### L-16: `deposit` Calls `_increaseBuffered` Before Transfer

**Source:** Building Secure Contracts (L-6)
**Location:** `OllaCore.sol:975-977`

Optimistic accounting before `safeTransferFrom`. Safe due to `nonReentrant` and post-transfer reconciliation, but reordering would be more defensive.

**Recommendation:** Transfer first, then increase buffered.

---

### 4.4 INFORMATIONAL

#### I-01: Unused Events in IOllaCore Interface

**Source:** Spec-to-Code Compliance
**Location:** `IOllaCore.sol:95-97, 118-123`

Three events declared but never emitted: `Withdraw`, `StakeRequested`, `UnstakeRequested`.

---

#### I-02: Unused Errors in IRewardsVault Interface

**Source:** Spec-to-Code Compliance
**Location:** `IRewardsVault.sol:28, 33`

Two errors declared but never used: `RewardsVault__Unauthorized`, `RewardsVault__InsufficientBalance`.

---

#### I-03: Unresolved TODO Comments

**Source:** Spec-to-Code Compliance
**Location:** `AztecTypes.sol:38,47`, `IRewardsVault.sol:63`

Three TODO comments remain in production code. Should be resolved before external audit.

---

#### I-04: Instant Redemption Returns Net But Consumes Gross From Buffer

**Source:** Sharp Edges (SE-13)
**Location:** `OllaCore.sol:1218-1274`

The function returns `netAssets` but decreases the buffer by `grossAssets`. Correct behavior but confusing API for integrators.

**Recommendation:** Add `previewRedeem(uint256 shares)` and `maxRedeem(address)` view functions.

---

#### I-05: Virtual Offset Pattern Underdocumented

**Source:** Sharp Edges (SE-14)
**Location:** `OllaCore.sol:1715-1729`

The `+1` pattern is correct but lacks NatSpec explaining the inflation attack mitigation.

**Recommendation:** Add a NatSpec comment referencing the design rationale.

---

#### I-06: Direct Token Transfers Silently Absorbed as Donations

**Source:** Sharp Edges (SE-17)
**Location:** `OllaCore.sol:745-755, 1517-1534`

Tokens sent directly to OllaCore are absorbed via `_syncBufferedWithBalance()`, benefiting all stAztec holders.

**Recommendation:** Document this behavior.

---

#### I-07: RewardsVault.withdrawToCore Sweeps Full Balance (Known)

**Source:** Variant Analysis (V-2.1)
**Location:** `RewardsVault.sol:100-113`

Intentional design matching StakingManager's documented sweep pattern.

---

#### I-08: QueueLib `uint128` Index Theoretical Overflow

**Source:** Sharp Edges (SE-16)
**Location:** `QueueLib.sol:42-49`

Practically unreachable with `uint128.max = 3.4 * 10^38`.

---

#### I-09: StAztec burn() Trust Assumption Documented

**Source:** Entry Point Analyzer (F-06)
**Location:** `StAztec.sol:57-62`

Correctly documented in NatSpec. See T-1 trust assumption.

---

#### I-10: SafetyModule Parameter Setters Lack Bounds (Informational)

**Source:** Entry Point Analyzer (F-07)
**Location:** `SafetyModule.sol:183-210`

Covered by M-03 above.

---

#### I-11: `12-Hour Attester State Max Age` May Be Permissive

**Source:** Insecure Defaults (Finding 11)
**Location:** `StakingManager.sol:32,181`

Default `DEFAULT_ATTESTER_STATE_MAX_AGE = 12 hours`. A slashing event could go undetected for up to 12 hours. Should be evaluated against Aztec's epoch/slashing cadence.

---

#### I-12: Storage Gap Arithmetic Needs Manual Verification

**Source:** Building Secure Contracts (L-5)
**Location:** All upgradeable contracts

OllaCore has 16 state variables + `uint256[47]` gap. Total slots should be verified.

---

## 5. Trust Assumptions Compliance

| ID  | Trust Assumption                                | Classification    | Notes                                                                                                              |
| --- | ----------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------ |
| T-1 | BURNER_ROLE held exclusively by OllaCore        | **PARTIAL_MATCH** | Role exclusivity not enforced in code — governance can grant to anyone via `grantRole`                             |
| T-2 | MINTER_ROLE held exclusively by OllaCore        | **PARTIAL_MATCH** | Same pattern as T-1                                                                                                |
| T-3 | OPERATOR_ROLE trusted for correct accounting    | **FULL_MATCH**    | Operator triggers reads from on-chain sources; circuit breakers bound influence                                    |
| T-4 | DEFAULT_ADMIN_ROLE can upgrade all UUPS proxies | **CODE_STRONGER** | OllaCore/SM/SPR add governance body check; WQ/RV use role check only                                               |
| T-5 | Governance can set fees up to 100%              | **FULL_MATCH**    | Validated 0-10000 BP                                                                                               |
| T-6 | Governance can hot-swap modules                 | **PARTIAL_MATCH** | Spec overstates — only RewardsVault is hot-swappable without proxy upgrade                                         |
| T-7 | Aztec rollup behaves correctly                  | **FULL_MATCH**    | Complete dependency with circuit breaker mitigations                                                               |
| T-8 | GUARDIAN can force-unpause stuck rebalance      | **CODE_STRONGER** | `forceRebalanceUnpause` requires `step == Done` — spec's stated impact (mid-rebalance inconsistency) is impossible |

---

## 6. Internal Audit Fix Verification

| ID   | Finding                                         | Severity | Status              | Evidence                                                                           |
| ---- | ----------------------------------------------- | -------- | ------------------- | ---------------------------------------------------------------------------------- |
| S-1  | WithdrawalQueue.claimWithdrawal griefing        | MEDIUM   | **PROPERLY FIXED**  | `onlyCore` modifier added at `WithdrawalQueue.sol:192`                             |
| S-2  | Non-upgradeable ReentrancyGuard in proxies      | LOW      | **PARTIALLY FIXED** | Tests added verifying behavior; still uses non-upgradeable import                  |
| S-3  | StAztec burn bypasses allowance                 | INFO     | **PROPERLY FIXED**  | Trust assumption documented in NatSpec at `StAztec.sol:57-62`                      |
| S-4  | StakingManager sweeps full balance              | LOW      | **PROPERLY FIXED**  | Documented as intentional recovery mechanism at `StakingManager.sol:751-759`       |
| S-5  | Rebalance pause blocks all operations           | MEDIUM   | **PARTIALLY FIXED** | `claimRequestById` unblocked during rebalance; deposits/new requests still blocked |
| S-6  | Head-of-line blocking in WithdrawalQueue        | LOW      | **PROPERLY FIXED**  | Documented as intentional at `WithdrawalQueue.sol:12-17`                           |
| S-7  | Redundant role checks on internal functions     | GAS      | **PROPERLY FIXED**  | Modifiers removed from `_payoutOllaProtocolFees` and `_calculateProtocolFees`      |
| S-8  | SafetyModule.core should be immutable           | GAS      | **PROPERLY FIXED**  | Changed to `address public immutable CORE` at `SafetyModule.sol:39`                |
| S-9  | Missing `assets > 0` validation in `_deposit`   | INFO     | **PROPERLY FIXED**  | Early check added at `OllaCore.sol:957-959`                                        |
| S-10 | Inconsistent access on setRebalanceGasThreshold | LOW      | **PROPERLY FIXED**  | Changed to `onlyRole(DEFAULT_ADMIN_ROLE)` at `OllaCore.sol:451`                    |

---

## 7. Code Maturity Assessment

| Category               | Rating   | Max   | Evidence                                                                              |
| ---------------------- | -------- | ----- | ------------------------------------------------------------------------------------- |
| Arithmetic             | 3.5      | 4     | `Math.mulDiv` with explicit rounding, virtual offset, `SafeCast`, no unchecked blocks |
| Auditing (Events)      | 4.0      | 4     | 28+ events covering all state changes; comprehensive monitoring support               |
| Auth/Access Controls   | 3.5      | 4     | Well-structured RBAC with `RolesLib`; `onlyCore` modifiers; dual upgrade checks       |
| Complexity Management  | 3.0      | 4     | Clean modular architecture; rebalance is 220 lines with high cyclomatic complexity    |
| Decentralization       | 2.0      | 4     | Operator-dependent; governance can upgrade and set 100% fees; no timelock             |
| Documentation          | 3.5      | 4     | NatSpec on all functions; 3 remaining TODOs                                           |
| MEV/Ordering           | 3.0      | 4     | Rebalance pause provides structural protection; no slippage params                    |
| Low-Level Manipulation | 4.0      | 4     | Zero assembly, zero delegatecall, zero unchecked in production                        |
| Testing/Verification   | 3.5      | 4     | 55 test files; invariant, fuzz, reentrancy, malicious mock testing                    |
| **Overall**            | **3.33** | **4** |                                                                                       |

---

## 8. Entry Point Analysis

### 8.1 Total Functions Analyzed: 48

| Risk       | Count | Examples                                                                                                                                                      |
| ---------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **HIGH**   | 17    | `deposit`, `redeem`, `rebalance`, `updateAccounting`, `setGovernance`, `mint`, `burn`, `stake`, `unstake`, `getUnstakedFunds`, `harvestRewards`, all upgrades |
| **MEDIUM** | 15    | `pause/unpause`, `reconcileBufferedAssets`, `recordBalance`, `computeAttesterState`, circuit breaker checks, key management                                   |
| **LOW**    | 16    | All fee/config setters, `setGasThreshold`, `setAttesterStateMaxAge`                                                                                           |

### 8.2 Functions Accessible by Anyone (No Role Check)

| Contract | Function                                       | Mitigation                                                     |
| -------- | ---------------------------------------------- | -------------------------------------------------------------- |
| OllaCore | `deposit()`, `depositWithPermit()`             | `whenNotPaused`, `whenNotRebalancePaused`, SafetyModule checks |
| OllaCore | `requestRedeem()`, `requestRedeemWithPermit()` | Requires stAztec balance                                       |
| OllaCore | `claimRequestById()`                           | Funds go to recorded recipient, not caller                     |
| OllaCore | `redeem()`, `redeemWithPermit()`               | Requires stAztec balance + sufficient liquidity                |
| StAztec  | `transfer()`, `approve()`, `permit()`          | Standard ERC-20                                                |

### 8.3 Functions Without Reentrancy Guard

| Contract                | Function                    | Risk       | Mitigation                            |
| ----------------------- | --------------------------- | ---------- | ------------------------------------- |
| OllaCore                | `reconcileBufferedAssets()` | Low        | View-only external call (`balanceOf`) |
| OllaCore                | `recoverStAztec()`          | Low        | Admin-only, trusted token             |
| StakingManager          | `computeAttesterState()`    | **Medium** | `onlyCoreOrOperator`, trusted rollup  |
| StakingProviderRegistry | `addKeysToProvider()`       | Low        | No external calls                     |

---

## 9. Variant Analysis

Starting from 8 known vulnerability patterns, 15 variants were identified across the codebase:

| Pattern                      | Variants Found | Most Significant                                     |
| ---------------------------- | -------------- | ---------------------------------------------------- |
| S-1: Missing access control  | 1              | `claimRequestById` permissionless (by design)        |
| S-4: Balance sweep           | 2              | RewardsVault also sweeps (intentional, documented)   |
| S-5: Rebalance pause scope   | 2              | `claimRequestById` correctly excluded (good design)  |
| S-6: Head-of-line blocking   | 3              | StakingManager loops use skip-ahead (not vulnerable) |
| S-7: Redundant role checks   | 2              | `_initiateUnstakeRequests` has redundant `onlyCore`  |
| S-9: Missing zero validation | 5              | `setMaxAccountingDelay(0)` bricks protocol           |
| First-depositor attack       | 0              | **Clean** — `+1` consistently applied everywhere     |
| Inconsistent UUPS auth       | 1              | WQ and RV lack governance body check                 |

**No additional inflation attack variants found** — the virtual offset pattern is comprehensive.

---

## 10. Missing Invariant Tests

### 10.1 Existing Coverage: 28 Invariants

| Contract        | Count | Key Properties                                                                                                              |
| --------------- | ----- | --------------------------------------------------------------------------------------------------------------------------- |
| OllaCore        | 14    | TotalAssets buckets, exchange rate, gross rewards, deposit monotonicity, lifecycle conservation, state machine forward-only |
| StAztec         | 1     | TotalSupply equals sum of balances                                                                                          |
| WithdrawalQueue | 4     | Pending amounts, pointer monotonicity, claimed-implies-finalized, pending-is-unfinalized                                    |
| StakingManager  | 13    | State non-negative, queue FIFO, attester consistency, balance consistency                                                   |

### 10.2 Missing Critical Invariants: 12

| ID      | Property                                                         | Why Critical                                                   |
| ------- | ---------------------------------------------------------------- | -------------------------------------------------------------- |
| **B1**  | `asset.balanceOf(core) >= bufferedAssets + finalizedUnclaimed`   | Vault solvency — can the vault honor all claims?               |
| **B2**  | Exchange rate monotonically non-decreasing across ALL operations | Currently only tested for deposits, not rebalance/rewards/fees |
| **B3**  | Deposit-redeem roundtrip: `convertToAssets(shares) <= assets`    | Prevents value extraction via share price manipulation         |
| **B4**  | `cumulativeDeposits` and `cumulativeWithdrawals` never decrease  | Corrupted flow counters break gross rewards computation        |
| **B5**  | `slashingDelta` monotonically non-decreasing                     | Prevents artificial totalAssets inflation                      |
| **B6**  | All requests with `id < nextPendingId` are finalized             | FIFO ordering integrity                                        |
| **B7**  | Total tokens across all contracts >= totalAssets                 | Master conservation law                                        |
| **B8**  | Instant redemption: `fee + netAssets == grossAssets`             | Fee accounting correctness                                     |
| **B9**  | Rebalance pause blocks user actions; completion lifts pause      | State machine liveness                                         |
| **B10** | After `recordBalance()`: `recorded == actual balance`            | RewardsVault consistency                                       |
| **B11** | `cumulativeRewards` never decreases                              | Prevents under-reporting of rewards                            |
| **B12** | Virtual offset prevents first-depositor value extraction         | Inflation attack defense validated under fuzz                  |

Suggested Foundry test implementations for all 12 invariants are available in the full Property-Based Testing analysis.

---

## 11. Differential Review of Recent Fixes

| Commit    | Description                                           | Risk   | Verdict                                                                               |
| --------- | ----------------------------------------------------- | ------ | ------------------------------------------------------------------------------------- |
| `b41702e` | First-depositor/inflation attack fix (virtual offset) | HIGH   | **Complete & correct** — `+1` consistently applied; 5 tests (2 fuzz)                  |
| `397e55e` | Rebalance deadlock on large withdrawals               | HIGH   | **Complete & correct** — both finalization loop and completion check fixed; 6 tests   |
| `0c3eb0f` | Gas optimizations and access control consistency      | MEDIUM | **Complete & correct** — grant-before-revoke order is safe; role modifiers cleaned up |
| `72ca3a4` | Reentrancy guard test coverage                        | MEDIUM | **Verified, no bypass** — 8+ scenarios with malicious mocks, all guards hold          |
| `e746583` | Rebalance idle guard test coverage                    | MEDIUM | **Complete & correct** — prevents infinite restart; correctly cleared on new work     |

**No bypass paths found in any of the 5 fixes.** All are correctly implemented with comprehensive test coverage.

---

## 12. DeFi-Specific Risks

### 12.1 Front-Running

| Vector                                        | Risk   | Mitigation                                            |
| --------------------------------------------- | ------ | ----------------------------------------------------- |
| Sandwich deposits around `updateAccounting()` | MEDIUM | Rebalance pause blocks user actions during accounting |
| Front-run `rebalance()` with deposit          | LOW    | Rebalance pauses at start, blocking deposits          |
| Back-run accounting to exit at better rate    | LOW    | `requestRedeem` locks rate at request time            |

### 12.2 Flash Loan Attacks

| Vector                                    | Risk | Mitigation                                           |
| ----------------------------------------- | ---- | ---------------------------------------------------- |
| Share inflation                           | LOW  | Virtual offset (+1) pattern                          |
| Exchange rate manipulation via donation   | LOW  | `bufferedAssets` tracked explicitly, not via balance |
| Flash deposit + instant redeem round-trip | LOW  | 5% fee makes this economically unviable              |

### 12.3 Oracle Manipulation

The exchange rate depends on `totalAssets()` which includes 5 accounting buckets. Most are read from trusted on-chain sources (rollup). Donation to `RewardsVault` could inflate `rewardsVaultBalance`, but the `recordBalance` mechanism accounts for increases as legitimate rewards.

### 12.4 Token Integration Assumptions

| Assumption         | What Breaks If Violated                                            |
| ------------------ | ------------------------------------------------------------------ |
| No fee-on-transfer | Deposits revert (safe failure mode via `_syncBufferedWithBalance`) |
| No rebasing        | `bufferedAssets` tracking becomes stale                            |
| No blocklist       | Claims/withdrawals permanently lock                                |
| Standard ERC-20    | Mitigated by `SafeERC20`                                           |

---

## 13. Positive Security Properties

1. **Virtual offset (+1) pattern** — protects against first-depositor/inflation attacks; no variants found
2. **Consistent `nonReentrant`** — all user-facing external functions across all contracts
3. **Zero low-level code** — no assembly, no delegatecall, no unchecked blocks in production
4. **SafeERC20** — used for all token operations
5. **Circuit breaker system** — automated protection against rate drops, queue imbalance, stale accounting
6. **Gas-bounded loops** — prevent out-of-gas griefing in rebalance and staking
7. **Storage gaps** — present in all 5 upgradeable contracts
8. **Dependencies pinned** — OZ 5.5.0, Aztec contracts at specific git rev
9. **`_disableInitializers()`** — correctly called in all 5 upgradeable constructors
10. **28 invariant tests** — covering accounting, exchange rate, queue ordering, state machine, token conservation
11. **55 test files** — including invariant, fuzz, reentrancy, integration, and malicious mock tests
12. **Grant-before-revoke** — governance transfer correctly prevents admin lockout window
13. **Rebalance idle guard** — prevents infinite restart loops
14. **Zero Slither findings** — clean static analysis (0.11.4 + Slytherin 0.7.2)

---

## 14. Recommendations

### Priority 1 — Before Mainnet

| #   | Action                                                                       | Finding |
| --- | ---------------------------------------------------------------------------- | ------- |
| 1   | Implement two-step governance transfer (`propose` + `accept`)                | H-01    |
| 2   | Add slippage protection: `minSharesOut` on deposit, `minAssetsOut` on redeem | M-01    |
| 3   | Add `totalAssets()` underflow protection (clamp to 0)                        | H-03    |
| 4   | Add timelock on governance actions (upgrades, fee changes, module swaps)     | M-07    |
| 5   | Bound SafetyModule thresholds with min/max validation                        | M-03    |
| 6   | Add governance body check to WQ and RV `_authorizeUpgrade`                   | M-06    |
| 7   | Add `forceRebalanceReset` or time-based emergency unpause                    | H-04    |

### Priority 2 — High Value

| #   | Action                                                            | Finding |
| --- | ----------------------------------------------------------------- | ------- |
| 8   | Cap fees at reasonable maximums (e.g., 50% protocol, 20% instant) | M-02    |
| 9   | Set non-zero default `targetBufferedAssets`                       | M-04    |
| 10  | Propagate governance changes to StakingManager/SPR                | M-08    |
| 11  | Add `nonReentrant` to `computeAttesterState()`                    | M-10    |
| 12  | Bound `setAttesterStateMaxAge` and move to ADMIN role             | M-12    |
| 13  | Bound `setRebalanceGasThreshold`                                  | M-05    |

### Priority 3 — Cleanup

| #   | Action                                                        | Finding    |
| --- | ------------------------------------------------------------- | ---------- |
| 14  | Remove redundant `onlyCore` from `_initiateUnstakeRequests`   | L-07       |
| 15  | Add `shares == 0` early check to `_requestRedeem`             | L-08       |
| 16  | Resolve TODO comments in AztecTypes.sol and IRewardsVault.sol | I-03       |
| 17  | Remove unused events/errors from interfaces                   | I-01, I-02 |
| 18  | Add NatSpec for virtual offset pattern                        | I-05       |
| 19  | Call `__UUPSUpgradeable_init()` in all upgradeable contracts  | L-13       |

### Priority 4 — New Invariant Tests

Implement the 12 missing invariant tests identified in Section 10, prioritizing:

1. B1 — Buffered assets solvency
2. B2 — Global exchange rate monotonicity
3. B5 — Slashing delta monotonicity
4. B7 — Cross-contract token conservation

---

_Report generated using Trail of Bits Claude Code Skills Marketplace. 9 skills applied: Entry Point Analyzer, Sharp Edges, Insecure Defaults, Audit Context Building, Spec-to-Code Compliance, Variant Analysis, Property-Based Testing, Building Secure Contracts, Differential Review._
