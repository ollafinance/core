# Local (Anvil)

This doc assumes you have a local deployment file at `deployments/local.json` (created by `yarn deploy:local`).

## RPC configuration

Configure Foundry to point at your local node via `FOUNDRY_ETH_RPC_URL`.

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
