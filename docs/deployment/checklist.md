# Deployment Checklist

Use this as the operator runbook for `contracts/script/Deploy.s.sol`.

## 1. Network model

- Deployment profile is selected by `ETHEREUM_CHAIN_ID`.
- Supported values: `31337` (local), `11155111` (sepolia), `1` (mainnet).
- `Deploy.s.sol` enforces `block.chainid == ETHEREUM_CHAIN_ID`.

## 2. Env setup

For live deploys, use `contracts/.env`:

- Copy `contracts/.env.example` to `contracts/.env`.
- Optionally copy values from one of these templates:
  - `contracts/.example-sepolia.env`
  - `contracts/.example-sepolia-mocked-aztec.env`
  - `contracts/.example-mainnet.env`
- Edit `contracts/.env` for your target live network.

For local deploys, `yarn deploy:local` uses:

- `contracts/.example-local.env`

Notes:

- Forge reads `contracts/.env` automatically when run from `contracts/`.
- Set both `SEPOLIA_RPC_URL` and `MAINNET_RPC_URL` in `.env` and choose alias with `--rpc-url sepolia` or `--rpc-url mainnet`.
- `yarn deploy:local` intentionally keeps using `contracts/.example-local.env`.

Per-network requirements:

- **Local (`31337`)**: `MOCK_AZTEC=true` and `TIMELOCK_DURATION=0` are typical defaults.
- **Sepolia (`11155111`)**: `PRIVATE_KEY`, explicit `MOCK_AZTEC`, and `LZ_ENDPOINT` are required.
- **Sepolia with real Aztec (`MOCK_AZTEC=false`)**: `ASSET` and `ROLLUP_REGISTRY` are required.
- **Mainnet (`1`)**: `PRIVATE_KEY`, `LZ_ENDPOINT`, `ASSET`, `ROLLUP_REGISTRY`, `GOVERNANCE`, `TREASURY`, `PROVIDER_ADMIN`, and `GUARDIAN` are required.
- **Mainnet**: `MOCK_AZTEC=true` is forbidden.
- **Strict address separation (Sepolia/Mainnet when `MOCK_AZTEC=false`)**:
  - `deployer` must differ from `governance`, `treasury`, `providerAdmin`, and `guardian`.
  - `governance` must differ from `providerAdmin`.

## 3. Preflight

- [ ] Install dependencies once: `cd contracts && forge soldeer install`
- [ ] Build: `yarn forge:build`
- [ ] Run tests: `yarn test`

## 4. Deploy

`DEPLOY_WITH_VERIFY=true` is an intent/guardrail flag checked by `Deploy.s.sol`; actual explorer verification only runs when `--verify` is included.

### Local (Anvil)

```bash
# terminal 1
yarn dev:chain

# terminal 2
yarn deploy:local
```

### Sepolia (enforced two-step flow)

```bash
cd contracts

# 1) dry-run
DEPLOY_STEP=dry-run forge script script/Deploy.s.sol --rpc-url sepolia

# NOTE: do not pass --broadcast for dry-run (enforced by Deploy.s.sol)

# 2) broadcast (no verify)
DEPLOY_STEP=broadcast DEPLOY_DRY_RUN_DONE=true DEPLOY_WITH_VERIFY=true \
forge script script/Deploy.s.sol --broadcast --rpc-url sepolia

# 3) optional separate verify pass
DEPLOY_STEP=broadcast DEPLOY_DRY_RUN_DONE=true DEPLOY_WITH_VERIFY=true \
forge script script/Deploy.s.sol --broadcast --verify --rpc-url sepolia
```

### Mainnet (enforced two-step flow)

```bash
cd contracts

# 1) dry-run
DEPLOY_STEP=dry-run forge script script/Deploy.s.sol --rpc-url mainnet

# NOTE: do not pass --broadcast for dry-run (enforced by Deploy.s.sol)

# 2) broadcast (no verify)
DEPLOY_STEP=broadcast DEPLOY_DRY_RUN_DONE=true DEPLOY_WITH_VERIFY=true \
forge script script/Deploy.s.sol --broadcast --rpc-url mainnet

# 3) optional separate verify pass
DEPLOY_STEP=broadcast DEPLOY_DRY_RUN_DONE=true DEPLOY_WITH_VERIFY=true \
forge script script/Deploy.s.sol --broadcast --verify --rpc-url mainnet
```

`Deploy.s.sol` enforces on strict chains:

- `DEPLOY_STEP` must be `dry-run` or `broadcast`.
- `DEPLOY_STEP=dry-run` cannot be executed with `--broadcast`.
- Broadcast requires `DEPLOY_DRY_RUN_DONE=true` and `DEPLOY_WITH_VERIFY=true`.

## 5. Resume after failure

If deploy/broadcast fails mid-run, rerun the same command with the same env values.

- Resume source: `deployments/<network>.json`.
- Default behavior: dry-run resume off, broadcast resume on.
- Optional override: set `DEPLOY_RESUME=true` to force resume in dry-run mode.

Rules:

- [ ] Do not hand-edit deployment addresses in `deployments/<network>.json`.
- [ ] If you hit `ADDRESS_STATE_MISMATCH` or `CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT`, fix env/config mismatch before retrying.

## 6. Post-deploy activation (strict chains)

On strict chains (Sepolia/Mainnet), deployment is complete but protocol is not fully operational
until governance actions execute (including when `TIMELOCK_DURATION=0`).

The canonical activation chain is 5 governance operations: `OllaGovernance.setCore` (scheduled at
deploy — execute it before reporting activation complete, or `emergencyPauseAll`/`emergencyUnpauseAll`
and the governance passthroughs stay unusable), then `OllaCore.setVault` → `OllaCore.unpause` →
`OllaCore.setRebalanceCooldown(86400)` → `OllaVault.unpause`. The cooldown step must run before the
vault is unpaused, otherwise the permissionless rebalance cadence stays at the 1h initializer default
instead of the intended 24h.

```bash
# Execute the deploy-scheduled OllaGovernance.setCore op (binds the timelock to Core).
# Use the activation payload printers below; setCore is step 1/2.
ETHEREUM_CHAIN_ID=<11155111-or-1> forge script script/ops/GovSetVault.s.sol --broadcast --rpc-url <sepolia-or-mainnet>
ETHEREUM_CHAIN_ID=<11155111-or-1> forge script script/ops/GovUnpauseCore.s.sol --broadcast --rpc-url <sepolia-or-mainnet>
ETHEREUM_CHAIN_ID=<11155111-or-1> REBALANCE_COOLDOWN=86400 \
  forge script script/ops/GovSetRebalanceCooldown.s.sol --broadcast --rpc-url <sepolia-or-mainnet>
ETHEREUM_CHAIN_ID=<11155111-or-1> REBALANCE_COOLDOWN=86400 \
  forge script script/ops/GovUnpauseVault.s.sol --broadcast --rpc-url <sepolia-or-mainnet>
```

`PrintNextActivationPayload.s.sol` (10 steps) or `PrintAllSchedulePayloads.s.sol` /
`PrintAllExecutePayloads.s.sol` generate the Safe payloads, including the `setCore` step and the
`setRebalanceCooldown` step. Each ops script is idempotent: first run may schedule, later run executes,
re-runs become no-op.

Optional override env vars for ops scripts:

- `GOVERNANCE_PROXY`, `CORE`, `VAULT`, `REBALANCE_COOLDOWN`

## 7. Post-deploy bridge hardening (LayerZero)

Peers must be configured before enforced options — a deployed adapter with no peer reverts on
`quoteSend`/`send` (`NoPeer`) and rejects inbound messages. See
`contracts/script/docs/live.md` (Post-deploy bridge hardening) for the full procedure.

- [ ] For each destination EID, `setPeer(destEid, peerBytes32)` on this chain's adapter (via governance).
- [ ] Configure the reciprocal `setPeer(homeEid, homeAdapterBytes32)` on the destination OFT/adapter.
- [ ] Verify `peers(destEid)` is nonzero and equals the expected peer for every EID, and that `owner()` is governance (not the deployer).
- [ ] Configure `StAztecOFTAdapter.setEnforcedOptions(...)` for each destination EID.
- [ ] Set msgType `1` (`SEND`) with a baseline receive gas budget (for example `200_000`).
- [ ] If `SEND_AND_CALL` is enabled, also set msgType `2` with a higher budget (`~350k-500k`).
- [ ] Treat the bridge as activated only after peers (both directions) and enforced options are verified.

## 8. Final verification

```bash
ETHEREUM_CHAIN_ID=<11155111-or-1> forge script script/ops/PrintDeployment.s.sol --rpc-url <sepolia-or-mainnet>
ETHEREUM_CHAIN_ID=<11155111-or-1> forge script script/ops/PrintState.s.sol --rpc-url <sepolia-or-mainnet>
```

- [ ] `deployments/<network>.json` exists (`local.json`, `sepolia.json`, or `mainnet.json`).
- [ ] `deployments/<network>.json` has compatible `mode.mockAztec` and `inputs.*` values for current env.
- [ ] `OllaGovernance.core()` points to `OllaCore` proxy.
- [ ] On strict chains, `OllaCore.vault()` is either unset (pre-activation) or points to `OllaVault` after `GovSetVault`.
- [ ] On non-strict chains with `TIMELOCK_DURATION==0`: `OllaCore.vault()` points to `OllaVault` proxy.
- [ ] On non-strict chains with `TIMELOCK_DURATION>0`: `OllaCore.vault()` stays unset until `GovSetVault` executes.
- [ ] `OllaCore.safetyModule()` points to the deployed SafetyModule.
- [ ] If `TIMELOCK_DURATION>0`: core and vault are unpaused only after governance ops scripts complete.
- [ ] On strict chains, deployer no longer retains governance admin roles (and, for non-mock deploys, SafetyModule guardian).
