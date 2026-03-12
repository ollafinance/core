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
