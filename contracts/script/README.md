# Contracts Scripts

Forge scripts used to deploy and operate Olla Core contracts.

## Layout

```
script/
├── Deploy.s.sol                  # main orchestrator
├── base/                         # shared helpers
├── config/                       # per-environment deploy config
├── deployers/                    # deploy modules used by Deploy.s.sol
├── ops/                          # operator scripts (rebalance/accounting/roles)
├── provider/                     # provider registry scripts (seed keys)
└── rollup/                       # mock rollup control scripts (tick/rate/bump/demos)
```

## Defaults + overrides

- `ETHEREUM_CHAIN_ID` selects deployment profile (`31337` local, `11155111` sepolia, `1` mainnet).
- Many scripts accept address env vars (e.g. `CORE`, `ROLLUP`) but will default to the values in `deployments/<network>.json`.
- Env vars always override the deployment file.
- Broadcast scripts default to the Anvil account-0 private key ONLY when `chainid == 31337`.

## Deploy flow

- Sepolia/Mainnet enforce a two-step operator flow in `Deploy.s.sol`:
  1. `DEPLOY_STEP=dry-run` without `--broadcast`
  2. `DEPLOY_STEP=broadcast` with `DEPLOY_DRY_RUN_DONE=true` and `DEPLOY_WITH_VERIFY=true`
- `Deploy.s.sol` validates `block.chainid == config.chainId` at runtime.
- Deploy state is checkpointed in `deployments/<network>.json`; rerunning after failure resumes and skips already-valid steps.

## Post-deploy: unpause

OllaCore starts **paused** after `initialize()`. Local dev deploys (`deployMocks`) auto-unpause during the deploy script. Production deploys remain paused — governance must call `unpause()` (requires `GUARDIAN_ROLE`) when ready to accept deposits.

On strict chains (Sepolia/Mainnet), activation is a timelock flow over 5 governance operations
(10 schedule + execute payloads):

1. schedule `OllaGovernance.setCore(core)` — already scheduled at deploy (salt 0); operators usually only execute it
2. execute `OllaGovernance.setCore(core)`
3. schedule `OllaCore.setVault(vault)`
4. execute `OllaCore.setVault(vault)`
5. schedule `OllaCore.unpause()`
6. execute `OllaCore.unpause()`
7. schedule `OllaCore.setRebalanceCooldown(86400)` — raise the 1h initializer default to 24h before the vault opens
8. execute `OllaCore.setRebalanceCooldown(86400)`
9. schedule `OllaVault.unpause()`
10. execute `OllaVault.unpause()`

`OllaGovernance.setCore` binds the timelock to Core; until it is executed, `emergencyPauseAll`/
`emergencyUnpauseAll` and the governance passthroughs are unusable. `setRebalanceCooldown` must run
before `OllaVault.unpause()` so the permissionless rebalance cadence is the intended 24h, not the 1h
initializer default. Override the cooldown target with `REBALANCE_COOLDOWN=<seconds>` (default `86400`).

Use `script/ops/PrintNextActivationPayload.s.sol` to print exactly one next payload based on current on-chain state:

```bash
ETHEREUM_CHAIN_ID=<11155111-or-1> forge script script/ops/PrintNextActivationPayload.s.sol --rpc-url <sepolia-or-mainnet>
```

The script prints:

- current step (`Step x/10`)
- multisig address (`governanceAdmin`)
- contract to call (`OllaGovernance`)
- one payload for the next action when actionable
- wait information (`timelock.readyAt`) when execution is not yet possible

`PrintAllSchedulePayloads.s.sol` / `PrintAllExecutePayloads.s.sol` print the whole batch at once.

## Docs

- [Local chain](./docs/local.md)
- [Live (Sepolia + Mainnet)](./docs/live.md)

## Env file examples

- `contracts/.example-local.env`
- `contracts/.example-sepolia.env`
- `contracts/.example-mainnet.env`

Use them with Forge by exporting variables in your shell, for example:

```bash
set -a; source .example-sepolia.env; set +a
forge script script/Deploy.s.sol --rpc-url sepolia
```
