# Live (Testnet + Mainnet)

Placeholder.

## Testnet

- `PRIVATE_KEY` is required (no default outside chain id 31337).
- Prefer using `deployments/testnet.json` (or your own `DEPLOY_ENV`) to store addresses.
- Env var addresses override the deployment file.

## Mainnet

- `PRIVATE_KEY` is required.
- Use a dedicated `DEPLOY_ENV` and deployment JSON for mainnet addresses.

## Post-Governance Transfer

After `OllaGovernance.acceptGovernance()` completes, the new governance address automatically
receives `PROPOSER_ROLE`, `EXECUTOR_ROLE`, and `CANCELLER_ROLE` on `OllaGovernance`, and
`DEFAULT_ADMIN_ROLE` is propagated to all satellite contracts (WithdrawalQueue, RewardsVault,
StakingManager, StakingProviderRegistry). The old governance's roles are revoked atomically.

### Checklist

> **Note:** `OllaCore` ownership (`Ownable2Step`) is not changed by governance transfer --
> `OllaGovernance` remains the owner. Only the timelock roles and satellite admin roles
> are transferred to the new governance admin.

> **Note:** `STAKING_PROVIDER_ADMIN_ROLE` on `StakingProviderRegistry` belongs to the
> staking provider, not governance. It is intentionally not touched during governance
> transfer.
