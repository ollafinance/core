# Timelock Plan (Option A: OpenZeppelin TimelockController)

## Goal
Introduce a governance timelock for all admin-level actions without modifying contracts, by making a TimelockController the `DEFAULT_ADMIN_ROLE` holder for all contracts.

## Scope
This plan covers all admin-controlled actions across:

- OllaCore
- WithdrawalQueue (UUPS)
- RewardsVault (UUPS)
- StakingManager (UUPS)
- StakingProviderRegistry (UUPS)
- StAztec
- SafetyModule

## Recommended Timelock Configuration

- **Delay:** 48 hours (tunable)
- **Proposer:** governance multisig
- **Executor:** governance multisig (or open executor if desired)
- **Admin:** governance multisig (or self-administered timelock)

## Deployment & Role Migration Steps

1. **Deploy TimelockController**
   - `minDelay = 48 hours`
   - `proposers = [governance multisig]`
   - `executors = [governance multisig]` (or `address(0)` for open execution)
   - `admin = governance multisig` (or `address(0)` to renounce admin once finalized)

2. **Transfer DEFAULT_ADMIN_ROLE to TimelockController**
   For each contract, execute:
   - `grantRole(DEFAULT_ADMIN_ROLE, timelock)`
   - `revokeRole(DEFAULT_ADMIN_ROLE, currentGovernance)`

3. **Preserve Operational Roles**
   Keep these roles directly on operational wallets (not timelocked):
   - `GUARDIAN_ROLE` (emergency pause/unpause)
   - `OPERATOR_ROLE` (rebalance/accounting routines)
   - `STAKING_PROVIDER_ADMIN_ROLE` (staking provider management)
   - `MINTER_ROLE` / `BURNER_ROLE` (assigned to OllaCore)

4. **Update Governance Address Checks for Upgrades**
   The following contracts require `msg.sender == governance` in `_authorizeUpgrade`:
   - OllaCore
   - StakingManager
   - StakingProviderRegistry

   To allow upgrades via the timelock, ensure **governance address equals timelock** by executing:
   - `OllaCore.setGovernance(timelock)`

   After this change:
   - Upgrades can be scheduled/executed by the timelock
   - `DEFAULT_ADMIN_ROLE` remains in timelock for all admin actions

5. **Operational Runbook**
   Governance actions become:
   - `schedule(target, value, data, predecessor, salt, delay)`
   - wait for delay
   - `execute(...)`

## Actions Timelocked vs. Immediate

**Timelocked (via DEFAULT_ADMIN_ROLE):**
- UUPS upgrades
- Fee changes (protocol / instant redemption / treasury split)
- Critical address changes (rewards vault, governance)
- Safety thresholds (rate drop, queue ratio, accounting delay, deposit cap)
- Role management (grant/revoke)

**Immediate (non-admin roles):**
- Emergency pause/unpause (guardian)
- Operator rebalances / accounting updates

## Risks & Mitigations

- **Risk:** Timelock delay slows emergency parameter fixes.
  - **Mitigation:** Keep `GUARDIAN_ROLE` for pause/unpause outside timelock.

- **Risk:** Single delay for all actions.
  - **Mitigation:** If needed later, add tiered timelocks (see exhausted options).

## Validation Checklist

- Timelock has `DEFAULT_ADMIN_ROLE` on all admin-controlled contracts
- Governance multisig has proposer/executor roles on timelock
- Governance address in OllaCore is set to timelock
- Upgrades scheduled via timelock succeed
- Guardian/operator flows still work immediately

## Follow-Up (Optional)

- Consider moving `STAKING_PROVIDER_ADMIN_ROLE` behind timelock if you want staking key changes delayed
- Consider open execution (executor = address(0)) for transparency
