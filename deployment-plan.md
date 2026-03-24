# On-Chain Upgrade Plan (Post-Deployment)

## Scope

- Upgrade all deployed proxy contracts to include fixes since deployment commit `efc246c`.
- Include governance upgrade that contains fix `414e4c41e5b5a9c0923462d5dd5280525e2a29b2`.
- Use strict multisig flow (timelock `schedule` + `execute`) with one payload generated per run.

## Upgrade Order

1. `WithdrawalQueueProxy`
2. `RewardsAccumulatorProxy`
3. `StakingProviderRegistryProxy`
4. `StakingManagerProxy`
5. `OllaVaultProxy`
6. `OllaCoreProxy`
7. `OllaGovernanceProxy` (last)

Each component has 2 timelock steps: schedule, then execute.
Total steps: 14.

## Why Governance Last

- Keeps a stable governance execution surface while upgrading satellites/core.
- Reduces risk of mixing old/new governance behavior mid-upgrade run.
- Applies `414e4c4` only after all upstream upgrades are complete.

## Script To Implement

- Add `contracts/script/ops/PrintNextProtocolUpgradePayload.s.sol`.
- Behavior: print exactly one next action for multisig submission based on live chain state.
- Output should match existing ops UX (`step`, `next.action`, `payload`, wait metadata, etc.).

## Candidate Implementation Resolution

Default source: `deployments/<env>.json` keys:

- `WithdrawalQueueImplementation`
- `RewardsAccumulatorImplementation`
- `StakingProviderRegistryImplementation`
- `StakingManagerImplementation`
- `OllaVaultImplementation`
- `OllaCoreImplementation`
- `OllaGovernanceImplementation`

Optional env overrides:

- `WITHDRAWAL_QUEUE_IMPLEMENTATION`
- `REWARDS_ACCUMULATOR_IMPLEMENTATION`
- `STAKING_PROVIDER_REGISTRY_IMPLEMENTATION`
- `STAKING_MANAGER_IMPLEMENTATION`
- `VAULT_IMPLEMENTATION`
- `CORE_IMPLEMENTATION`
- `GOVERNANCE_IMPLEMENTATION`

## Safety / Idempotence Rules

- Compare current proxy implementation vs candidate by:
  - exact address
  - runtime codehash
- Treat as already upgraded if either check matches.
- Skip upgraded components and move to the next one.

## Predecessor Bug Guard

To avoid deadlocked predecessor chains (same class as prior activation bug):

- Canonical predecessor is previous operation id.
- If previous component is already upgraded but its canonical operation is not `done`
  (e.g. manual/off-path execution, different salt), set predecessor to `bytes32(0)`.
- This guarantees the next operation remains schedulable.

## Governance Upgrade Encoding

- For satellites: `OllaGovernance.upgradeSatellite(proxy, impl)`
- For core: `OllaGovernance.upgradeCore(impl)`
- For governance proxy (last): timelock self-call to
  `OllaGovernanceProxy.upgradeToAndCall(impl, "")`

## Verification Checklist

Before each action:

- `forge script script/ops/PrintGovernanceRoles.s.sol --rpc-url <network>`
- Confirm multisig has proposer/executor rights.

After each execute:

- Rerun `PrintNextProtocolUpgradePayload` and confirm next step changes.
- Optionally run `forge script script/ops/PrintState.s.sol --rpc-url <network>`.

Final checks:

- Script returns `next.action = none` and `next.status = upgrade_complete`.
- Governance transfer role propagation fix behavior is present in upgraded governance implementation.

## Execution Flow

1. Deploy all new implementations and store addresses.
2. Use one fixed `SALT` across the full campaign.
3. Repeatedly run print script, submit exactly one returned payload, wait for timelock readiness, rerun.
4. Stop only when script reports complete.
