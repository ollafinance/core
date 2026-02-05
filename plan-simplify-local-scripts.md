# Plan: Simplify Local Forge Scripts (Deployment Defaults + Split Docs)

## Goals

- Make operator/provider/rollup scripts default to the addresses in `contracts/deployments/<DEPLOY_ENV>.json`.
- Keep env vars as overrides (power users can still point scripts at arbitrary deployments).
- Make scripts runnable on local Anvil with minimal setup:
  - no address env vars required
  - no `PRIVATE_KEY` required (default to Anvil account-0 key)
- Split docs under `contracts/script/`:
  - `contracts/script/README.md`: overview only
  - `contracts/script/docs/local.md`: local workflows, no hardcoded addresses, no `--rpc-url ...`, no `PRIVATE_KEY` in examples
  - `contracts/script/docs/live.md`: placeholder for testnet+mainnet

## Non-goals

- Changing protocol contract behavior.
- Changing deployment JSON format.
- Making live/testnet scripts “zero-config” (live networks must require `PRIVATE_KEY`).

## Design

### 1) Standard script env + defaults

Introduce a small helper layer used by scripts to resolve:

- `DEPLOY_ENV` defaults to `local`.
- Address resolution:
  1. Use `vm.envOr(<VAR>, address(0))` if set.
  2. Else read `contracts/deployments/<DEPLOY_ENV>.json` via `_tryReadDeployment(env, <DEPLOY_KEY>)`.
  3. `require(addr != address(0), <error message>)`.

- Private key resolution:
  - If `PRIVATE_KEY` is set, use it.
  - Else: allow an Anvil default private key ONLY when `block.chainid == 31337`.
  - Else: revert with a clear message.

Rationale: chain-id gating avoids the “DEPLOY_ENV=local but pointing at a live RPC” footgun.

### 2) Deployment key mapping

Use existing deployment keys (already written by local deploy) as defaults:

- `CORE` -> `OllaCoreProxy`
- `REGISTRY` -> `StakingProviderRegistryProxy`
- `ROLLUP` -> `MockAztecRollup`
- `COINBASE` (RewardsVault coinbase) -> `RewardsVaultProxy`
- `ASSET` -> `Asset` (if needed by scripts)

### 3) Script-by-script changes

Refactor scripts currently using `vm.envAddress(...)` to use the helper resolver.

- `contracts/script/provider/AddKeys.s.sol`
  - `REGISTRY` defaults to `StakingProviderRegistryProxy`
  - `COUNT` defaults to `5`
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

- `contracts/script/ops/Rebalance.s.sol`
  - `CORE` defaults to `OllaCoreProxy`
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

- `contracts/script/ops/UpdateAccounting.s.sol`
  - `CORE` defaults to `OllaCoreProxy`
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

- `contracts/script/ops/GrantOperator.s.sol`
  - `CORE` defaults to `OllaCoreProxy`
  - `TARGET` defaults to broadcaster (`vm.addr(pk)`)
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

- `contracts/script/rollup/TickRewards.s.sol`
  - `ROLLUP` defaults to `MockAztecRollup`
  - `COINBASE` defaults to `RewardsVaultProxy`
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

- `contracts/script/rollup/SetRewardRate.s.sol`
  - `ROLLUP` defaults to `MockAztecRollup`
  - `RATE` remains required (no default)
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

- `contracts/script/rollup/AddRewards.s.sol`
  - `ROLLUP` defaults to `MockAztecRollup`
  - `COINBASE` defaults to `RewardsVaultProxy`
  - `AMOUNT` remains required
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

- `contracts/script/rollup/SetActivationThreshold.s.sol`
  - `ROLLUP` defaults to `MockAztecRollup`
  - `THRESHOLD` remains required
  - `PRIVATE_KEY` defaults to Anvil key on chain 31337

Note: keep `contracts/script/ops/PrintDeployment.s.sol`, `contracts/script/ops/PrintState.s.sol`, and `contracts/script/rollup/DemoFinalizeWithdraw.s.sol` aligned with the same conventions (especially `_pk()` behavior).

### 4) Docs split

#### `contracts/script/README.md` (overview only)

- Directory structure and intent of each folder.
- How scripts resolve defaults:
  - `DEPLOY_ENV` + deployment JSON
  - env vars override deployment JSON
- Links:
  - `contracts/script/docs/local.md`
  - `contracts/script/docs/live.md`

No step-by-step demos here.

#### `contracts/script/docs/local.md`

Constraints (explicitly enforce in content):

- No examples with `ROLLUP=0x...` / `CORE=0x...` etc.
- No `--rpc-url ...` in commands.
- No `PRIVATE_KEY=...` in commands.

Use patterns instead:

- Mention `FOUNDRY_ETH_RPC_URL` as the preferred configuration knob (no hardcoded URL).
- Show tunables in examples (e.g. `COUNT`, `THRESHOLD`, `RATE`, `AMOUNT`, `TARGET`) and add trailing comments:
  - `# TARGET defaults to broadcaster`
  - `# COUNT defaults to 5`
  - `# COINBASE defaults to RewardsVaultProxy`
  - `# ROLLUP defaults to MockAztecRollup`

Include sections:

- Prereqs (Anvil running, local deployment exists)
- Inspect state (PrintDeployment/PrintState)
- Rewards loop (SetRewardRate/TickRewards/Rebalance/UpdateAccounting)
- Provider keys (AddKeys)
- Stake withdraw demo (DemoFinalizeWithdraw)

#### `contracts/script/docs/live.md` (placeholder)

- Two top-level sections: Testnet + Mainnet.
- State that `PRIVATE_KEY` is required on live networks.
- Describe how to override addresses via env vars when no deployment JSON is present.

## Implementation steps

1. Add helper functions (new base or extend `BaseDeployer`): `_env()`, `_pk()`, `_addrOrDeployment(...)`, `_uintOr(...)`.
2. Refactor scripts listed above to use the helper functions.
3. Split docs:
   - rewrite `contracts/script/README.md` as overview
   - add `contracts/script/docs/local.md`
   - add `contracts/script/docs/live.md` placeholder
4. Run formatting (`forge fmt`) on changed scripts.
5. Local smoke test:
   - Run each script with no address env vars and no `PRIVATE_KEY` env var.

## Acceptance criteria

- On Anvil (chain id 31337), the following work without specifying any addresses and without setting `PRIVATE_KEY`:
  - `forge script script/ops/PrintDeployment.s.sol`
  - `forge script script/ops/PrintState.s.sol`
  - `forge script script/rollup/TickRewards.s.sol --broadcast`
  - `forge script script/ops/Rebalance.s.sol --broadcast`
  - `forge script script/ops/UpdateAccounting.s.sol --broadcast`
  - `forge script script/provider/AddKeys.s.sol --broadcast` (with `COUNT` optional)
- On non-31337 chains, scripts that broadcast revert with a clear message unless `PRIVATE_KEY` is set.
- Docs exist at:
  - `contracts/script/README.md`
  - `contracts/script/docs/local.md`
  - `contracts/script/docs/live.md`
  and `local.md` contains no hardcoded addresses, no `--rpc-url`, and no `PRIVATE_KEY` usage.
