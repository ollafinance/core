# Interfaces and Roles

## External interfaces

### OllaCore

| Function | Arguments | Returns | Access | Description |
| --- | --- | --- | --- | --- |
| `deposit` | `uint256 assets`, `address recipient` | `uint256 shares` | `public` | Accept deposit and mint `stAztec` using `exchangeRate` |
| `requestRedeem` | `uint256 shares`, `address recipient` | `uint256 requestId` | `public` | Burns `shares` and queues a FIFO withdraw request |
| `claimActiveRequest` | `address owner` | `uint256 assets` | `public` | Claim a finalized request using the owner mapping |
| `claimRequestById` | `uint256 requestId` | `uint256 assets` | `public` | Claim a finalized request by id |
| `rebalance` | `—` | `—` | `OPERATOR_ROLE` | Harvest -> finalize withdrawals -> stake excess |
| `updateAccounting` | `—` | `—` | `OPERATOR_ROLE` | Pull validator state -> update rate -> mint fees |
| `finalizeWithdrawals` | `uint256 availableForWithdrawals` | `uint256 used` | `OPERATOR_ROLE` | Completes withdrawals based on liquidity |
| `totalAssets` | `—` | `uint256` | `view` | Returns protocol AUM per invariant |
| `pause` | `—` | `—` | `GUARDIAN_ROLE` | Freeze deposits and finalization |
| `unpause` | `—` | `—` | `GUARDIAN_ROLE` | Resume protocol |

### StAztec

| Function | Arguments | Returns | Access | Description |
| --- | --- | --- | --- | --- |
| `mint` | `address to`, `uint256 amount` | `—` | `MINTER_ROLE` | Mint LST on deposit or protocol fee |
| `burn` | `address from`, `uint256 amount` | `—` | `BURNER_ROLE` | Burn LST when withdrawal initiated |
| `permit` | `owner`, `spender`, `value`, `deadline`, `v`, `r`, `s` | `—` | `public` | EIP-2612 gasless approval |
| `totalSupply` | `—` | `uint256` | `view` | ERC20 supply |
| `balanceOf` | `address account` | `uint256` | `view` | User stAztec balance |
| `transfer` | `address to`, `uint256 amount` | `bool` | `public` | Standard ERC20 transfer |

### RewardsVault

| Function | Arguments | Returns | Access | Description |
| --- | --- | --- | --- | --- |
| `receiveRewards` | `uint256 amount` | `—` | `external` | Aztec rewards inflow handler |
| `withdrawToCore` | `uint256 amount` | `—` | `CORE_ROLE` | Sends rewards to `OllaCore` when required |
| `balance` | `—` | `uint256` | `view` | Vault-held rewards |
| `setTreasury` | `address treasury` | `—` | `DEFAULT_ADMIN_ROLE` | Change treasury target address |

### StakingManager

| Function | Arguments | Returns | Access | Description |
| --- | --- | --- | --- | --- |
| `stake` | `uint256 amount` | `—` | `CORE_ROLE` | Stakes capital using queued validator key |
| `unstake` | `uint256 amount` | `—` | `CORE_ROLE` | Begin validator withdrawal flow |
| `getUnstakedFunds` | `—` | `uint256 received` | `CORE_ROLE` | Claims matured unstakes to core |
| `harvestRewards` | `—` | `uint256 harvested` | `CORE_ROLE` | Claims sequencer rewards to RewardsVault |
| `addKeysToProvider` | `KeyStore[] keystores` | `—` | `STAKING_PROVIDER_ADMIN_ROLE` | Adds attester keys into queue |
| `dripQueue` | `uint256 count` | `—` | `STAKING_PROVIDER_ADMIN_ROLE` | Rotates or activates keys |
| `getStakingState` | `—` | `StakingState` | `view` | Aggregated staking state from the rollup |

### WithdrawalQueue

| Function | Arguments | Returns | Access | Description |
| --- | --- | --- | --- | --- |
| `requestWithdrawal` | `address user`, `uint256 shares`, `uint256 assets`, `uint256 rate` | `uint256 requestId` | `CORE_ROLE` | Enqueue withdrawal at locked rate |
| `finalizeWithdrawals` | `uint256 availableAssets` | `uint256 usedAssets` | `CORE_ROLE` | FIFO finalization based on liquidity |
| `claimWithdrawal` | `uint256 requestId` | `uint256 assets` | `public` | Withdraw finalized funds |
| `getRequest` | `uint256 requestId` | `WithdrawalRequest` | `view` | Returns struct info |
| `nextUnfinalized` | `—` | `uint256` | `view` | Queue head pointer |

### SafetyModule

| Function | Arguments | Returns | Access | Description |
| --- | --- | --- | --- | --- |
| `checkDepositAllowed` | `uint256 deposit`, `uint256 total` | `bool` | `CORE_ROLE` | Enforces TVL limit |
| `checkRateDrop` | `uint256 old`, `uint256 next` | `—` | `CORE_ROLE` | Circuit breaks on abnormal loss |
| `checkQueueRatio` | `uint256 queued`, `uint256 total` | `—` | `CORE_ROLE` | Breaks if queue pressure too high |
| `setDepositCap` | `uint256 cap` | `—` | `DEFAULT_ADMIN_ROLE` | Adjust TVL ceiling |
| `pause` | `—` | `—` | `GUARDIAN_ROLE` | Emergency shutdown |
| `unpause` | `—` | `—` | `GUARDIAN_ROLE` | Recovery unpause |
| `isPaused` | `—` | `bool` | `view` | Status check |

## Roles and permissions matrix

All roles implemented via OpenZeppelin AccessControl.

| Role | Holder | Permissions |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | GuardianMultisig | Manage all roles and upgrades. |
| `GUARDIAN_ROLE` | GuardianMultisig | Pause or unpause, adjust `SafetyModule` caps and thresholds, reset breakers. |
| `OPERATOR_ROLE` | Protocol operator wallet | Call `rebalance()` and `updateAccounting()` on `OllaCore`. |
| `CORE_ROLE` | OllaCore (on other modules) | Mint or burn stAztec, create or finalize withdrawals, invoke staking or unstaking and reward harvesting. |
| `STAKING_PROVIDER_ADMIN_ROLE` | Node operator or provider admin | Add validator keys, manage provider queue, rotate provider admin. |
| `MINTER_ROLE` / `BURNER_ROLE` (StAztec) | OllaCore | Mint or burn stAztec. |
