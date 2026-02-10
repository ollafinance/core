# Local (Anvil)

This doc assumes you have a local deployment file at `deployments/local.json` (created by `yarn deploy:local`).

## RPC configuration

Scripts need an RPC endpoint. For local Anvil, either:

1. Set the profile: `export FOUNDRY_PROFILE=local`
2. Or pass explicitly: `forge script ... --rpc-url http://127.0.0.1:8545`

The examples below assume `FOUNDRY_PROFILE=local` is set.

## Address + signer defaults

- `DEPLOY_ENV` defaults to `local`.
- Addresses default to `deployments/<DEPLOY_ENV>.json` when possible.
- Scripts default to Anvil account-0 for signing when `chainid == 31337`.

## Inspect

```bash
cd contracts

forge script script/ops/PrintDeployment.s.sol
forge script script/ops/PrintState.s.sol
```

## Rewards loop

```bash
cd contracts

RATE=1000000000000000000 forge script script/rollup/SetRewardRate.s.sol --broadcast  # ROLLUP defaults to MockAztecRollup
forge script script/rollup/TickRewards.s.sol --broadcast  # COINBASE defaults to RewardsVaultProxy
forge script script/ops/Rebalance.s.sol --broadcast  # CORE defaults to OllaCoreProxy
forge script script/ops/UpdateAccounting.s.sol --broadcast  # CORE defaults to OllaCoreProxy
```

## Local dev (3 terminals)

term-1:

```bash
yarn dev:chain
```

term-2:

```bash
yarn deploy:local && yarn dev:mock-loop
```

With the new TypeScript mock loop, all operations are automated via scenarios configured in `mock-loop/config.ts`. The default config runs:

1. **Provider keys** - Maintains minimum keys in registry
2. **Mock rewards** - Sets reward rate and ticks rewards each block
3. **User deposit** - Mints and deposits 200k tokens at tick 1
4. **Rebalance** - Runs operator rebalance every 10 ticks
5. **Accounting** - Updates accounting every 10 ticks  
6. **User withdraw** - Initiates withdrawal at tick 20
7. **User claim** - Claims finalized withdrawals from tick 50

### One-off tick

Run a single tick and exit:

```bash
yarn dev:mock-tick
```

### Custom config

```bash
yarn dev:mock-loop --config ./my-config.ts
```

Defaults:

- God/admin/operator: Anvil account-0.
- User: Anvil account-1 (configured via private key in scenarios).
- Output: `mock-loop/runs/<timestamp>/` with `init.json`, `tick-NNN.json`, and `log.jsonl`.

Notes:

- `deploy:local` seeds provider keys automatically, so staking can start immediately.
- The mock loop only accrues rewards when there is rollup stake.
- Scenario timing and amounts can be customized by editing `mock-loop/config.ts`.

## Provider keys

```bash
cd contracts

COUNT=5 forge script script/provider/AddKeys.s.sol --broadcast  # REGISTRY defaults to StakingProviderRegistryProxy; COUNT defaults to 5
```

## Grant operator

```bash
cd contracts

TARGET=0x0000000000000000000000000000000000000001 forge script script/ops/GrantOperator.s.sol --broadcast  # TARGET defaults to broadcaster
```

## Finalize withdraw demo

```bash
cd contracts

THRESHOLD=10000000000000000000 forge script script/rollup/DemoFinalizeWithdraw.s.sol --broadcast  # ROLLUP defaults to MockAztecRollup; ATTESTER/RECIPIENT default to broadcaster
```
