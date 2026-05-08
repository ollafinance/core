# Trust Assumptions

This document enumerates the critical trust assumptions that underpin the Olla protocol's security model. Each assumption represents a design decision where the protocol deliberately grants elevated privileges to a specific role or external dependency. These are **by design, not bugs** — but violating any of them can have severe consequences.

This serves two purposes:

1. **For the development team and governance:** a checklist of invariants that must be maintained across upgrades, role grants, and module replacements.
2. **For external auditors:** a clear declaration of what the protocol considers in-scope trust versus out-of-scope trust, reducing ambiguity during audit engagements.

## Privileged Roles

The protocol has 3 privileged roles:

**OllaGovernance (timelock)** — holds `DEFAULT_ADMIN_ROLE` on all contracts; 2-day minimum delay on proposals controlling upgrades (`upgradeCore`, `upgradeSatellite`), fourteen parameter setters (`setCore`, `setStakingManager`, `setSafetyModule`, `setInstantRedemptionFeeBP`, `setMaxInstantRedemptionFeeBP`, `setMinRebalancingCooldown`, `setTreasuryFeeBP`, `setProviderFeeBP`, `setMinRateDropBps`, `setMaxQueueRatioBps`, `setMaxAccountingDelay`, `setDepositCap`, `setMinProposalDelay`, `setGovernanceAdmin`), and role grants; emergency pause/unpause (`emergencyPauseAll`, `emergencyUnpauseAll`) executes instantly without timelock via separate `governanceAdmin` role.

**GUARDIAN_ROLE** — pauses/unpauses OllaCore, OllaVault, SafetyModule instantly via `pause`/`unpause`; resets rebalance state machine via `forceRebalanceReset` (does not modify accounting or touch funds); cannot change parameters or access user funds.

**STAKING_PROVIDER_ADMIN_ROLE** — adds attester keys to StakingProviderRegistry via `dripQueue`; sets rewards recipient per provider via `setProviderRewardsRecipient`; not subject to timelock; cannot access protocol funds or modify system parameters.

## Assumptions

| # | Assumption | Contracts | Impact if Violated |
|---|---|---|---|
| T-1 | Only the immutable `OLLA_VAULT` address can burn stAztec | StAztec | Any other caller able to burn can confiscate arbitrary users' staking positions without allowance |
| T-2 | Only the immutable `OLLA_VAULT` address can mint stAztec | StAztec | Any other caller able to mint can create unbacked stAztec, diluting all existing holders |
| T-3 | Governance can upgrade all UUPS proxies (OllaCore/OllaVault via `Ownable2Step` owner; the rest via `DEFAULT_ADMIN_ROLE`) | OllaCore, OllaVault, RewardsAccumulator, StakingManager, StakingProviderRegistry, OllaGovernance (self-upgrade) | A compromised governance key can replace any implementation, which would be a full protocol rug |
| T-4 | Governance can set protocol fees up to 50% (`MAX_PROTOCOL_FEE_BP = 5_000`) | OllaCore | Fee misconfiguration can extract up to half of yield from stakers |
| T-5 | Governance can hot-swap `SafetyModule` (`OllaCore.setSafetyModule`) and replace any other satellite via UUPS upgrade | OllaCore | Replacing a module with a malicious contract can drain assets or corrupt state |
| T-6 | The Aztec rollup and registry contracts behave correctly | StakingManager | If the canonical rollup is compromised, staked funds and rewards are at risk |
| T-7 | `GUARDIAN_ROLE` can pause/unpause and force-reset a stuck rebalance | OllaCore | A malicious guardian can disrupt protocol availability; force-resetting mid-rebalance discards in-progress work (unharvested rewards wait for next cycle, partial unstakes are tracked on-chain) |
| T-8 | `STAKING_PROVIDER_ADMIN_ROLE` can add attester keys to the registry and set per-provider rewards recipients; not subject to timelock | StakingProviderRegistry | A compromised key can register malicious attesters or redirect provider rewards, but cannot access vault funds, staked assets, or modify protocol parameters |

## Design Decisions

### Rebalance and accounting are permissionless

`rebalance()`, `updateAccounting()`, and `refreshAttesterState(address[])` are callable by any address. There is no operator as a liveness dependency; anyone can advance the protocol's state machine. `refreshAttesterState` delta-updates the aggregate staking state per attester and finalizes exits when applicable. It replaces the previous `computeAttesterState()` and `finalizeExits()` functions with an event-driven, idempotent design. Rate-limiting is enforced by a governance-configurable cooldown (`rebalanceCooldown`, bounded to 10 min to 24 h) that prevents new rebalance cycles from starting too frequently. All accounting data is derived from on-chain state (rollup attester views, RewardsAccumulator balance), not operator-submitted values.

`reconcileBufferedAssets()` is gated by `onlyOwner` (governance) on `OllaVault` because it has donation-absorption side effects that must remain privileged.

### SafetyModule is intentionally non-UUPS

SafetyModule uses plain `AccessControl` (not upgradeable) with an `immutable CORE`. This is deliberate:

1. **Trust anchor**: SafetyModule is the protocol's circuit breaker / pause mechanism. Making it silently upgradeable would undermine its purpose — users must be able to reason about what can pause the protocol without worrying about implementation swaps.
2. **Simple logic, small attack surface**: Its functionality (deposit caps, rate-drop breakers, queue-ratio breakers, accounting liveness) is straightforward and unlikely to need in-place patching.
3. **Setter escape hatch**: `OllaCore.setSafetyModule()` (admin-only, requires unpaused + no active rebalance) allows replacing the module without a full UUPS upgrade of the core proxy.
4. **No funds, no cross-contract references**: SafetyModule holds no assets and is only referenced by OllaCore, so swapping it carries no consistency risk (contrast with RewardsAccumulator, which holds funds and is referenced by StakingManager).

## Mitigations

- **T-1 and T-2** are enforced by an immutable address check in StAztec — no governance action can change the authorized caller, so these hold as long as the StAztec contract is not redeployed.
- **T-3 through T-5** are governance-controlled risks. The primary mitigation is a **timelocked multisig** for all admin and role-grant operations, giving the community a window to react to malicious proposals.
- **T-6** is an external dependency risk. The protocol relies on the Aztec rollup behaving as specified. Circuit breakers in SafetyModule (rate drop, accounting staleness) provide partial protection.
- **T-7** is mitigated by separating `GUARDIAN_ROLE` from `DEFAULT_ADMIN_ROLE` — the guardian can pause but cannot upgrade or drain.
- **T-8** is mitigated by scoping the role to two narrow operations (key registration and rewards recipient) that cannot access vault funds or modify protocol parameters. Governance can revoke the role at any time.
