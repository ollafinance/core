# Trust Assumptions

This document enumerates the critical trust assumptions that underpin the Olla protocol's security model. Each assumption represents a design decision where the protocol deliberately grants elevated privileges to a specific role or external dependency. These are **by design, not bugs** — but violating any of them can have severe consequences.

This serves two purposes:

1. **For the development team and governance:** a checklist of invariants that must be maintained across upgrades, role grants, and module replacements.
2. **For external auditors:** a clear declaration of what the protocol considers in-scope trust versus out-of-scope trust, reducing ambiguity during audit engagements.

## Assumptions

| # | Assumption | Contracts | Impact if Violated |
|---|---|---|---|
| T-1 | Only the immutable `OLLA_VAULT` address can burn stAztec | StAztec | Any other caller able to burn can confiscate arbitrary users' staking positions without allowance |
| T-2 | Only the immutable `OLLA_VAULT` address can mint stAztec | StAztec | Any other caller able to mint can create unbacked stAztec, diluting all existing holders |
| T-3 | `OPERATOR_ROLE` can set attester-state staleness window | StakingManager | A malicious operator can set an excessively large `attesterStateMaxAge`, allowing stale slashing/staking data to persist and delaying accurate accounting |
| T-4 | `DEFAULT_ADMIN_ROLE` (governance) can upgrade all UUPS proxies | OllaCore, WithdrawalQueue, RewardsAccumulator, StakingManager, StakingProviderRegistry | A compromised governance key can replace any implementation — full protocol rug |
| T-5 | Governance can set protocol fees up to 50% (`MAX_PROTOCOL_FEE_BP = 5_000`) | OllaCore | Fee misconfiguration can extract up to half of yield from stakers |
| T-6 | Governance can hot-swap modules (StakingManager, RewardsAccumulator, WithdrawalQueue, SafetyModule) | OllaCore | Replacing a module with a malicious contract can drain assets or corrupt state |
| T-7 | The Aztec rollup and registry contracts behave correctly | StakingManager | If the canonical rollup is compromised, staked funds and rewards are at risk |
| T-8 | `GUARDIAN_ROLE` can pause/unpause and force-reset a stuck rebalance | OllaCore | A malicious guardian can disrupt protocol availability; force-resetting mid-rebalance discards in-progress work (unharvested rewards wait for next cycle, partial unstakes are tracked on-chain) |

## Design Decisions

### Rebalance and accounting are permissionless

`rebalance()`, `updateAccounting()`, `computeAttesterState()`, and `finalizeExits()` are callable by any address. This eliminates the operator as a liveness dependency — anyone can advance the protocol's state machine. Rate-limiting is enforced by a governance-configurable cooldown (`rebalanceCooldown`, bounded to 10 min–24 h) that prevents new rebalance cycles from starting too frequently. All accounting data is derived from on-chain state (rollup attester views, rewards vault balances), not operator-submitted values.

`reconcileBufferedAssets()` was moved from `OPERATOR_ROLE` to `DEFAULT_ADMIN_ROLE` (governance) because it has donation-absorption side effects that should remain privileged.

### SafetyModule is intentionally non-UUPS

SafetyModule uses plain `AccessControl` (not upgradeable) with an `immutable CORE`. This is deliberate:

1. **Trust anchor**: SafetyModule is the protocol's circuit breaker / pause mechanism. Making it silently upgradeable would undermine its purpose — users must be able to reason about what can pause the protocol without worrying about implementation swaps.
2. **Simple logic, small attack surface**: Its functionality (deposit caps, rate-drop breakers, queue-ratio breakers, accounting liveness) is straightforward and unlikely to need in-place patching.
3. **Setter escape hatch**: `OllaCore.setSafetyModule()` (admin-only, requires unpaused + no active rebalance) allows replacing the module without a full UUPS upgrade of the core proxy.
4. **No funds, no cross-contract references**: SafetyModule holds no assets and is only referenced by OllaCore, so swapping it carries no consistency risk (contrast with RewardsAccumulator, which holds funds and is referenced by StakingManager).

## Mitigations

- **T-1 and T-2** are enforced by an immutable address check in StAztec — no governance action can change the authorized caller, so these hold as long as the StAztec contract is not redeployed.
- **T-3 through T-6** are governance-controlled risks. The primary mitigation is a **timelocked multisig** for all admin and role-grant operations, giving the community a window to react to malicious proposals.
- **T-7** is an external dependency risk. The protocol relies on the Aztec rollup behaving as specified. Circuit breakers in SafetyModule (rate drop, accounting staleness) provide partial protection.
- **T-8** is mitigated by separating `GUARDIAN_ROLE` from `DEFAULT_ADMIN_ROLE` — the guardian can pause but cannot upgrade or drain.
