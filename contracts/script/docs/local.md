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
- The Anvil account-1 private key shown below is a default test account and only for local development.

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

## Mint tokens

```bash
cd contracts

AMOUNT=200000 forge script script/local/MintAztecTo.s.sol --broadcast  # TO defaults to Anvil account-1
```

## User operations

```bash
cd contracts

# Deposit
AMOUNT=100000 PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  forge script script/local/UserDeposit.s.sol --broadcast

# Initiate withdrawal (full balance)
PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  forge script script/local/UserInitiateWithdrawAll.s.sol --broadcast

# Claim finalized withdrawals
PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  forge script script/local/UserClaimWithdrawals.s.sol --broadcast
```
