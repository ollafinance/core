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

- `DEPLOY_ENV` defaults to `local`.
- Many scripts accept address env vars (e.g. `CORE`, `ROLLUP`) but will default to the values in `deployments/<DEPLOY_ENV>.json`.
- Env vars always override the deployment file.
- Broadcast scripts default to the Anvil account-0 private key ONLY when `chainid == 31337`.

## Docs

- [Local chain](./docs/local.md)
- [Live (testnet + mainnet)](./docs/live.md)
