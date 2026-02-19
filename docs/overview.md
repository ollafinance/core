# Olla Protocol Overview

Olla Core is the on-chain vault and staking coordinator for liquid staking on Aztec. It accepts user deposits, manages async withdrawals, and delegates staking operations to Aztec rollup contracts via the staking manager.

## Architecture overview

```mermaid
---
config:
  layout: elk
---
flowchart LR

subgraph "Actors"
    user[User]
    governanceActor[Governance]
    guardianActor[Guardian]
    ollaOperatorActor[Olla Protocol Operator]
    stakingProviderActor[Staking Provider Admin]
end

subgraph "Wallets"
    userWallet[User]
    stakingProviderAdminWallet[Staking Provider Admin]
    stakingProviderRewardsWallet[Staking Provider Rewards]
    guardianWallet[Guardian]
    ollaOperatorWallet[Olla Protocol Operator]
    governanceAdminWallet[Governance Admin]
    treasury[Governance Treasury]
    user --- userWallet
    stakingProviderActor --- stakingProviderAdminWallet
    stakingProviderActor --- stakingProviderRewardsWallet
    guardianActor --- guardianWallet
    ollaOperatorActor --- ollaOperatorWallet
    governanceActor --- treasury
    governanceActor --- governanceAdminWallet
    governanceAdminWallet -->|"DEFAULT_ADMIN_ROLE (pre-timelock)"| governanceAdminWallet
    timelock[TimelockController]
    governanceAdminWallet -->|"proposer/executor/admin"| timelock
end

subgraph "Olla Core"
    core[OllaCore]
    safety[SafetyModule]
    withdrawQ[WithdrawalQueue]
end
subgraph "Olla Staking Components"
    rewards[RewardsVault]
    stkMan[StakingManager]
    spr[StakingProviderRegistry]
end

stakingProviderAdminWallet -->|"admin functions"| spr

subgraph "Aztec Contracts"
    rollupRegistry[AztecRollupRegistry]
    rollup["AztecRollup (canonical)"]
end

guardianWallet -. "GUARDIAN_ROLE" .-> core
guardianWallet -. "GUARDIAN_ROLE" .-> safety

ollaOperatorWallet -. "OPERATOR_ROLE" .-> core
stakingProviderAdminWallet -. "STAKING_PROVIDER_ADMIN_ROLE" .-> spr
timelock -. "DEFAULT_ADMIN_ROLE" .-> core
timelock -. "DEFAULT_ADMIN_ROLE" .-> safety
timelock -. "DEFAULT_ADMIN_ROLE" .-> withdrawQ
timelock -. "DEFAULT_ADMIN_ROLE" .-> rewards
timelock -. "DEFAULT_ADMIN_ROLE" .-> stkMan
timelock -. "DEFAULT_ADMIN_ROLE" .-> spr

%% User flows (asset + call-path)
userWallet -->|"deposit/requestRedeem/claimActiveRequest"| core

core -->|"request-,claim-,finalize-withdrawal"| withdrawQ

core -->|"checkDepositAllowed / checkWithdrawalMinimum / checkQueueRatio / checkAccountingLiveness"| safety

%% Operator cycle (end-state orchestration)
ollaOperatorWallet -->|"computeAttesterState()"| stkMan
ollaOperatorWallet -->|"rebalance()"| core
ollaOperatorWallet -->|"setRebalanceGasThreshold()"| core
ollaOperatorWallet -->|"harvestRewards()"| core
ollaOperatorWallet -->|"finalizeWithdrawals(available)"| core
ollaOperatorWallet -->|"updateAccounting()"| core

%% Guardian control
guardianWallet -->|"forceRebalanceUnpause()"| core

%% Staking principal (AZTEC token) movements
core -->|"stake >Aztec< transferFrom(core, StakingManager, stakeAmount)"| stkMan
stkMan -->|"getAttesterKeystore()"| spr
stkMan -->|"deposit >Aztec< transferFrom(StakingManager, AztecRollup, stakeAmount)"| rollup

core -->|"unstake(amount)"| stkMan
stkMan -->|"initiateWithdraw"| rollup

core -->|"claimUnstakedFunds >Aztec< transferFrom(StakingManager, core, unstakedAmount)"| stkMan
stkMan -->|"finalizeWithdraw >Aztec< transferFrom(rollup, StakingManager, unstakedAmount)"| rollup

core -->|"harvestRewards()"| stkMan
stkMan -->|"getCanonicalRollup()"| rollupRegistry
rollupRegistry -->|"canonical rollup"| rollup
stkMan -->|"claimSequencerRewards(coinbase=rewardsVault)"| rollup
rollup -->|"rewards >Aztec< transferFrom(rollup, rewardsVault, amount)"| rewards
core -->|"recordBalance(expectedRewards)"| rewards

core -->|"finalizeWithdrawals(available)"| withdrawQ

core -->|"balance()"| rewards

core -->|"pay staking fees >StAztec< mint(governance, treasuryShares)"| treasury
core -->|"pay staking fees >StAztec< mint(providerRewardsRecipient, providerShares)"| stakingProviderRewardsWallet

%% Staking provider admin (control-plane)

style user fill:#900
style ollaOperatorActor stroke:#050,stroke-width:2px
style stakingProviderActor fill:#009
style rollup stroke:#ff6,stroke-width:2px
style core stroke:#090,stroke-width:4px
style safety stroke:#090,stroke-width:3px
style rewards stroke:#090,stroke-width:3px
style stkMan stroke:#090,stroke-width:3px
style spr stroke:#090,stroke-width:3px
style withdrawQ stroke:#090,stroke-width:3px
style rollupRegistry stroke:#ff6,stroke-width:2px
style guardianActor stroke:#050,stroke-width:2px
style governanceActor stroke:#050,stroke-width:2px
```

## Action references

- User flows: [docs/user-actions.md](docs/user-actions.md)
- Operator flows: [docs/operator-actions.md](docs/operator-actions.md)
- Governance flows: [docs/governance-actions.md](docs/governance-actions.md)
