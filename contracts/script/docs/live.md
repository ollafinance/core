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
- Optional deployment defaults: `PROTOCOL_FEE_BP`, `TREASURY_FEE_SPLIT_BP`, `SAFETY_DEPOSIT_CAP`, `SAFETY_MIN_RATE_DROP_BPS`, `SAFETY_MAX_QUEUE_RATIO_BPS`, `SAFETY_MAX_ACCOUNTING_DELAY`, `PROVIDER_REWARDS_RECIPIENT`

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

## Deployment parameter env vars

- `PROTOCOL_FEE_BP`: OllaCore initial protocol fee, default `500`.
- `TREASURY_FEE_SPLIT_BP`: OllaCore initial treasury fee split, default `5000`.
- `SAFETY_DEPOSIT_CAP`: SafetyModule initial deposit cap in raw asset units, default `1000000000000000000000000000`.
- `SAFETY_MIN_RATE_DROP_BPS`: SafetyModule initial rate-drop threshold, default `500`.
- `SAFETY_MAX_QUEUE_RATIO_BPS`: SafetyModule initial queued-withdrawal ratio threshold, default `5000`.
- `SAFETY_MAX_ACCOUNTING_DELAY`: SafetyModule initial accounting-liveness delay in seconds, default `7200`.
- `PROVIDER_REWARDS_RECIPIENT`: initial staking provider rewards recipient, default `PROVIDER_ADMIN`.
- `REBALANCE_COOLDOWN` is not an initializer env var today. OllaCore initializes to `1 hours`; the canonical activation chain (`PrintNextActivationPayload.s.sol`) raises it to `86400` (24h) via governance between `unpauseCore` and `unpauseVault`. Override the target with `REBALANCE_COOLDOWN=<seconds>` when generating activation payloads.
- `REBALANCE_GAS_THRESHOLD` is not an initializer env var today. OllaCore initializes to `180000`; set it after activation through governance with `setRebalanceGasThreshold(...)` if needed.

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

`GUARDIAN_ROLE` is granted to `OllaGovernance` during initialization of Core and Vault. `GUARDIAN` is granted `GUARDIAN_ROLE` on SafetyModule. The governance contract exposes emergency pause/unpause functions callable by the `governanceAdmin` (multisig) -- no timelock delay.

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

### Stuck-rebalance recovery (`forceRebalanceReset`)

If a rebalance is wedged in a non-`Done` state, simply unpausing is not enough: governance setters and
accounting paths guarded by `whenRebalanceDone` stay blocked until the rebalance state machine is reset.
`OllaCore.forceRebalanceReset()` clears the rebalance state machine (idle/snapshot fields,
`lastRebalanceTimestamp`) and emits `RebalanceReset`. It does not modify accounting or move funds.

`forceRebalanceReset()` is gated by Core `GUARDIAN_ROLE`. In the default deployment that role is held by
the `OllaGovernance` timelock contract — **not** the `governanceAdmin` EOA — so unlike
`emergencyPauseAll`/`emergencyUnpauseAll`, the reset is **not** an instant admin action. It must be
scheduled and executed as a timelock operation (use `PrintForceRebalanceResetPayload.s.sol` /
`GovForceRebalanceReset.s.sol`), unless a separate Core guardian wallet has been granted, in which case
that wallet can call `forceRebalanceReset()` directly.

Stuck-rebalance recovery sequence:

1. `emergencyPauseAll()` by the governance admin (instant).
2. `forceRebalanceReset()` through the timelock (schedule, wait for delay, execute), or directly by a
   configured separate Core guardian.
3. `emergencyUnpauseAll()` by the governance admin (instant).
4. Refresh attester state and resume `rebalance()` after the cooldown elapses.

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

# 3) Set rebalance cooldown to 24h (requires Core unpaused; setter has whenNotPaused)
ETHEREUM_CHAIN_ID=<11155111-or-1> REBALANCE_COOLDOWN=86400 \
forge script script/ops/GovSetRebalanceCooldown.s.sol --broadcast --rpc-url <sepolia-or-mainnet>

# 4) Unpause OllaVault
ETHEREUM_CHAIN_ID=<11155111-or-1> \
forge script script/ops/GovUnpauseVault.s.sol --broadcast --rpc-url <sepolia-or-mainnet>
```

`PrintNextActivationPayload.s.sol` reflects the same 4-step chain (8 total payloads — schedule + execute for each step) with predecessor chaining enforced through the timelock. Override the cooldown target with `REBALANCE_COOLDOWN=<seconds>`; default is `86400` (24 hours).

Expected behavior per run:

- First run typically schedules the operation.
- A later run (after timelock delay) executes it.
- Re-running after completion is a safe no-op.

Optional address overrides:

- `GOVERNANCE_PROXY`, `CORE`, `VAULT` (defaults read from `deployments/<env>.json`)

## Post-deploy bridge hardening (LayerZero)

Deploying `StAztecOFTAdapter` and the canonical endpoint is **not** sufficient for a working bridge.
The adapter is a thin `OFTAdapter` wrapper over the inherited OApp/OFT implementation, which requires
a trusted peer to be configured per destination before any outbound `quoteSend`/`send` works and before
inbound messages are accepted.

### Step 1 (mandatory): set and verify LayerZero peers

`OAppCore.setPeer(uint32 eid, bytes32 peer)` is `onlyOwner` (the production owner/delegate, i.e. governance).
Until `peers[destEid]` is nonzero, `quoteSend`/`send` revert with `NoPeer(destEid)`, and inbound receive
rejects any source whose sender does not match the configured peer. Skipping this step leaves a deployed,
"hardened" adapter that is still nonfunctional.

For each destination EID:

1. Encode the destination peer address to `bytes32` (left-padded; use `OptionsBuilder`/`addressToBytes32`
   semantics — the 20-byte EVM address right-aligned in 32 bytes).
2. Call `setPeer(destEid, peerBytes32)` on this chain's adapter through governance.
3. Configure the **reciprocal** peer on the destination: `setPeer(homeEid, homeAdapterBytes32)` on the
   destination OFT/adapter so the return path resolves back to this adapter.
4. Verify before treating the bridge as ready:

```bash
# Peer configured for each destination EID (must be nonzero and equal the expected peer bytes32)
cast call <ADAPTER> "peers(uint32)(bytes32)" <DEST_EID> --rpc-url <sepolia-or-mainnet>

# Owner/delegate is governance, not the deployer
cast call <ADAPTER> "owner()(address)" --rpc-url <sepolia-or-mainnet>
```

Only after every configured EID has a verified peer (both directions) and enforced options set should the
bridge be reported as activated. `setEnforcedOptions` alone is **not** complete bridge hardening.

### Step 2: set enforced options

After peers are configured, set enforced options via governance as a hardening step.

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

### Adapter is a single non-replaceable lockbox — peer rotation procedure

`StAztecOFTAdapter` is a lock/unlock adapter: outbound sends **lock** stAztec in the adapter holding the
backing, and returning sends **unlock** by transferring stAztec out of the *receiving* adapter's own
balance. The home-chain adapter set as the destination peer must therefore be the same adapter that holds
the locked stAztec backing outstanding destination supply. Only one funded adapter may exist per global OFT
mesh.

Consequence: if you rotate the destination peer from a funded home adapter to a fresh replacement adapter
while destination supply is still outstanding (and locked stAztec has not been migrated), a user returning
from the destination chain burns their bridged token first, then the home unlock fails because the
replacement adapter has no stAztec to release. The packet strands and the returning user's funds are
unavailable until operators fund/migrate the replacement adapter or otherwise remediate.

Before any `setPeer` that changes a home adapter address, treat the adapter as non-replaceable unless:

1. Outstanding destination supply is zero, **or**
2. Locked stAztec has first been migrated from the old adapter to the replacement, and no packets are
   in flight to the old adapter.

Pre-rotation checklist:

```bash
# Old adapter must hold no locked backing (or you must migrate it first)
cast call <OLD_ADAPTER> "balanceOf"  # via the stAztec token: stAztec.balanceOf(oldAdapter) == 0
# Replacement adapter balance and reciprocal peer state
# Confirm: outstanding destination supply == 0, no in-flight packets to old/new adapter,
#          reciprocal peer on the destination points at the intended adapter
```

If a packet has already been created against a replacement adapter that cannot unlock it, recovery is to
fund/migrate the replacement adapter with the equivalent locked stAztec so the pending unlock can complete.

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
receives `PROPOSER_ROLE`, `EXECUTOR_ROLE`, and `CANCELLER_ROLE` on `OllaGovernance` and becomes
the `governanceAdmin`. The old governance admin's timelock roles and its `DEFAULT_ADMIN_ROLE`
on `OllaGovernance` are revoked.

`DEFAULT_ADMIN_ROLE` is **not** granted to the incoming external wallet — neither on
`OllaGovernance` nor on the satellite contracts. Satellite `DEFAULT_ADMIN_ROLE` / owner authority
stays with the `OllaGovernance` contract address, which does not change on rotation; the new admin
steers satellites by scheduling timelock actions, not by holding satellite admin directly.

Notes:

- `OllaCore` owner remains `OllaGovernance`; transfer updates only the timelock roles and the `governanceAdmin` pointer.
- `STAKING_PROVIDER_ADMIN_ROLE` belongs to staking provider ops and is not changed by governance transfer.

Post-transfer verification:

- Confirm `address(gov)` still holds satellite `DEFAULT_ADMIN_ROLE` / owner authority on Core, Vault, SafetyModule, RewardsAccumulator, StakingManager, and StakingProviderRegistry.
- Confirm the new governance wallet holds `PROPOSER_ROLE`/`EXECUTOR_ROLE`/`CANCELLER_ROLE` and is `governanceAdmin`, but does **not** hold satellite `DEFAULT_ADMIN_ROLE`. Do not grant it directly unless governance intentionally wants to bypass the timelock-admin model.
