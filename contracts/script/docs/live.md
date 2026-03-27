# Live (Sepolia + Mainnet)

This guide documents deployment and operations for live networks.

## Core env model

- `ETHEREUM_CHAIN_ID` is required and must match your `--rpc-url` target.
- Supported values:
  - `11155111` (Sepolia)
  - `1` (Mainnet)
- Deploy script enforces `block.chainid == ETHEREUM_CHAIN_ID`.

## Required env vars

### Sepolia (`ETHEREUM_CHAIN_ID=11155111`)

- `PRIVATE_KEY`
- `MOCK_AZTEC` (must be explicitly set to `true` or `false`)
- `LZ_ENDPOINT` (must be defined; may be `0x0000000000000000000000000000000000000000`)
- If `MOCK_AZTEC=false`: `ASSET`, `ROLLUP_REGISTRY`, `GOVERNANCE`, `TREASURY`, `PROVIDER_ADMIN`, `GUARDIAN` (all required; deployer must differ from each, and `GOVERNANCE` must differ from `PROVIDER_ADMIN`)
- If `MOCK_AZTEC=true`: `GOVERNANCE` is optional. If omitted, it defaults to deployer.

### Mainnet (`ETHEREUM_CHAIN_ID=1`)

- `PRIVATE_KEY`
- `LZ_ENDPOINT` (required)
- `ASSET`, `ROLLUP_REGISTRY` (required)
- `GOVERNANCE`, `TREASURY`, `PROVIDER_ADMIN`, `GUARDIAN` (required)
- `MOCK_AZTEC=true` is forbidden

## Two-step deployment flow (enforced)

On Sepolia and Mainnet, use:

1. Dry-run

```bash
ETHEREUM_CHAIN_ID=<11155111-or-1> \
DEPLOY_STEP=dry-run \
... forge script script/Deploy.s.sol --rpc-url <sepolia-or-mainnet>

# NOTE: do not pass --broadcast for dry-run (enforced by Deploy.s.sol)
```

2. Broadcast + verify intent

```bash
ETHEREUM_CHAIN_ID=<11155111-or-1> \
DEPLOY_STEP=broadcast DEPLOY_DRY_RUN_DONE=true DEPLOY_WITH_VERIFY=true \
... forge script script/Deploy.s.sol --broadcast --rpc-url <sepolia-or-mainnet> --verify
```

## Resume after failure

If a broadcast fails mid-run, rerun the same command with the same env values.
`Deploy.s.sol` resumes from `deployments/<network>.json` and reuses already-valid addresses/state.

Resume behavior by mode:

- `DEPLOY_STEP=dry-run`: resume is disabled by default; deploy scripts ignore existing artifacts to avoid stale-address failures.
- `DEPLOY_STEP=broadcast`: resume is enabled by default.
- Optional override: set `DEPLOY_RESUME=true` to force resume in dry-run mode.

Notes:

- Never hand-edit deployment addresses in `deployments/<network>.json`.
- If the script reports `ADDRESS_STATE_MISMATCH` or `CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT`, stop and resolve the mismatch before retrying.
- Use status fields for progress visibility:
  - `status.phase` (`A`/`B`/`C`/`D`)
  - `status.completed`
  - `status.updatedAtBlock`

## Address separation rules (Sepolia/Mainnet)

- Deployer must differ from each of: `GOVERNANCE`, `TREASURY`, `PROVIDER_ADMIN`, `GUARDIAN`
- `GOVERNANCE` and `PROVIDER_ADMIN` must differ

Notes:

- These separation rules are enforced for strict **non-mock** deployments.
- Mock strict deployments may intentionally run with `GOVERNANCE == deployer`.

## Timelock defaults

- Sepolia default: `TIMELOCK_DURATION=3600`
- Mainnet default: `TIMELOCK_DURATION=172800`
- Override by setting `TIMELOCK_DURATION` explicitly

## Post-deploy expectations

- On strict chains (Sepolia/Mainnet), deployment does not auto-activate protocol state.
  Activation always runs via governance ops scripts (setVault + unpause), including `TIMELOCK_DURATION=0`.
- Deployer temporary governance roles are renounced when `GOVERNANCE != deployer`.
- If `GOVERNANCE == deployer` (mock strict flows), deployer roles are intentionally retained.
- On strict chains, deployer must not retain SafetyModule guardian privilege
- Deploy script enforces that governance operational control is not orphaned:
  - pre-renounce checks require configured governance to hold proposer/executor/canceller
  - post-deploy checks require at least one holder for proposer/executor/canceller

## Emergency pause

`GUARDIAN_ROLE` is granted to `OllaGovernance` during initialization of Core, Vault, and SafetyModule.
The governance contract exposes emergency pause/unpause functions callable by the `governanceAdmin`
(multisig) — no timelock delay.

### Global pause/unpause

`emergencyPauseAll()` pauses both OllaCore and OllaVault in a single transaction.
SafetyModule is intentionally omitted since it is only reachable through Core and Vault.

```bash
# Pause everything
cast send <GOVERNANCE_PROXY> "emergencyPauseAll()" --private-key <GOV_ADMIN_KEY> --rpc-url <sepolia-or-mainnet>

# Unpause everything (also no timelock)
cast send <GOVERNANCE_PROXY> "emergencyUnpauseAll()" --private-key <GOV_ADMIN_KEY> --rpc-url <sepolia-or-mainnet>
```

The SafetyModule circuit breaker can also auto-pause on rate drops, queue ratio spikes, or accounting staleness.

### Recovery

- `emergencyUnpauseAll()` is the fastest recovery path (no timelock).
- Alternatively, use the governance timelock scripts (`GovUnpauseCore.s.sol`, `GovUnpauseVault.s.sol`).
- If the guardian key is compromised: revoke `GUARDIAN_ROLE` via governance, grant to a new address, then unpause.

## Post-deploy activation (strict chains)

On strict chains, deployment is complete but protocol activation is an explicit governance flow.
Run from `contracts/` with the same signer used for governance execution.

```bash
# 1) Wire OllaCore -> OllaVault
ETHEREUM_CHAIN_ID=<11155111-or-1> \
forge script script/ops/GovSetVault.s.sol --broadcast --rpc-url <sepolia-or-mainnet>

# 2) Unpause OllaCore
ETHEREUM_CHAIN_ID=<11155111-or-1> \
forge script script/ops/GovUnpauseCore.s.sol --broadcast --rpc-url <sepolia-or-mainnet>

# 3) Unpause OllaVault
ETHEREUM_CHAIN_ID=<11155111-or-1> \
forge script script/ops/GovUnpauseVault.s.sol --broadcast --rpc-url <sepolia-or-mainnet>
```

Expected behavior per run:

- First run typically schedules the operation.
- A later run (after timelock delay) executes it.
- Re-running after completion is a safe no-op.

Optional address overrides:

- `GOVERNANCE_PROXY`, `CORE`, `VAULT` (defaults read from `deployments/<env>.json`)

## Post-deploy bridge hardening (LayerZero)

After deploying `StAztecOFTAdapter`, set enforced options via governance as a hardening step.

Example (`SEND`, msgType `1`):

```solidity
bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

EnforcedOptionParam[] memory params = new EnforcedOptionParam[](1);
params[0] = EnforcedOptionParam({
    eid: destEid,
    msgType: 1,
    options: options
});

StAztecOFTAdapter(adapter).setEnforcedOptions(params);
```

If `SEND_AND_CALL` is enabled in your flow, also set msgType `2` with an execution budget around `350k-500k` gas.

## Final verification after activation

```bash
# Address sanity
ETHEREUM_CHAIN_ID=<11155111-or-1> forge script script/ops/PrintDeployment.s.sol --rpc-url <sepolia-or-mainnet>

# Protocol state sanity
ETHEREUM_CHAIN_ID=<11155111-or-1> forge script script/ops/PrintState.s.sol --rpc-url <sepolia-or-mainnet>
```

Role checks (`cast`) to confirm operational posture:

- Governance retains `DEFAULT_ADMIN_ROLE`/guardian privileges on core and vault.
- Deployer no longer has governance admin/proposer/executor/canceller on strict chains.

## Post-Governance Transfer

After `OllaGovernance.acceptGovernance()` completes, the new governance address automatically
receives `PROPOSER_ROLE`, `EXECUTOR_ROLE`, and `CANCELLER_ROLE` on `OllaGovernance`, and
`DEFAULT_ADMIN_ROLE` is propagated to satellite contracts. The old governance roles are revoked.

Notes:

- `OllaCore` owner remains `OllaGovernance`; transfer updates timelock roles/admin roles.
- `STAKING_PROVIDER_ADMIN_ROLE` belongs to staking provider ops and is not changed by governance transfer.
