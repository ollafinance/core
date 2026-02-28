# Proposed Architecture: Vault + Core Split

## Architecture overview

```mermaid
---
config:
  layout: elk
---
flowchart LR

subgraph Actors
    user[User]
    anyone[Anyone]
    governanceActor[Governance]
    guardianActor[Guardian]
    ollaOperatorActor[Olla Protocol Operator]
    stakingProviderActor[Staking Provider Admin]
end

subgraph Wallets
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
end

subgraph OllaGov[Olla Governance]
    ollaGov["OllaGovernance (timelock)"]
end

governanceAdminWallet -->|"proposer/executor/canceller"| ollaGov

subgraph OllaVaultGroup["Olla Vault (user-facing)"]
    vault["OllaVault (ERC-7540 / ERC-7575 / ERC-4626)"]
    stAztec[StAztec]
    withdrawQ[WithdrawalQueue]
    safety[SafetyModule]
end

subgraph OllaCoreGroup["Olla Core (orchestration + accounting)"]
    core[OllaCore]
end

subgraph OllaStaking[Olla Staking Components]
    rewards[RewardsVault]
    stkMan[StakingManager]
    spr[StakingProviderRegistry]
end

subgraph AztecContracts[Aztec Contracts]
    rollupRegistry[AztecRollupRegistry]
    rollup["AztecRollup (canonical)"]
end

ollaGov -->|"owner"| vault
ollaGov -->|"owner"| core
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> safety
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> withdrawQ
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> rewards
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> stkMan
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> spr

userWallet -->|"deposit / mint"| vault
userWallet -->|"requestRedeem"| vault
userWallet -->|"claimRedeem / instantRedeem"| vault

vault -->|"mint on deposit"| stAztec
vault -->|"burn on redeem"| stAztec
vault -->|"request / claim / finalize withdrawal"| withdrawQ
vault -->|"deposit + withdrawal checks"| safety
vault -.->|"view: totalAssets / convertToShares / convertToAssets"| core

core -.->|"view: bufferedAssets / pendingWithdrawalAssets"| vault
core -->|"CORE_ROLE: transferToStaking / receiveUnstaked / finalizeWithdrawals"| vault
core -->|"checkQueueRatio / checkRateDrop / checkAccountingLiveness"| safety

anyone -->|"rebalance (cooldown-gated)"| core
anyone -->|"updateAccounting"| core
anyone -->|"finalizeExits"| stkMan
anyone -->|"computeAttesterState"| stkMan

guardianWallet -->|"pause / unpause / forceRebalanceReset"| core
guardianWallet -->|"pause / unpause"| vault
guardianWallet -. "GUARDIAN_ROLE" .-> safety

ollaOperatorWallet -->|"setRebalanceGasThreshold"| core
ollaOperatorWallet -->|"setAttesterStateMaxAge"| stkMan
stakingProviderAdminWallet -->|"addKeysToProvider / dripQueue"| spr

core -->|"stake via vault.transferToStaking"| stkMan
stkMan -->|"getAttesterKeystore"| spr
stkMan -->|"deposit"| rollup

core -->|"unstake"| stkMan
stkMan -->|"initiateWithdraw / finalizeWithdraw"| rollup

core -->|"getUnstakedFunds, route to vault"| stkMan
core -->|"harvestRewards"| stkMan
stkMan -->|"getCanonicalRollup"| rollupRegistry
rollupRegistry --> rollup
stkMan -->|"claimSequencerRewards coinbase=rewardsVault"| rollup
rollup -->|"rewards AZTEC"| rewards
core -->|"recordBalance / balance"| rewards

core -->|"mintFees stAztec to treasury"| treasury
core -->|"mintFees stAztec to provider"| stakingProviderRewardsWallet

style user fill:#900
style anyone fill:#555
style ollaOperatorActor stroke:#050,stroke-width:2px
style stakingProviderActor fill:#009
style rollup stroke:#ff6,stroke-width:2px
style rollupRegistry stroke:#ff6,stroke-width:2px
style vault stroke:#09f,stroke-width:4px
style core stroke:#090,stroke-width:4px
style safety stroke:#090,stroke-width:3px
style rewards stroke:#090,stroke-width:3px
style stkMan stroke:#090,stroke-width:3px
style spr stroke:#090,stroke-width:3px
style withdrawQ stroke:#090,stroke-width:3px
style stAztec stroke:#09f,stroke-width:3px
style ollaGov stroke:#090,stroke-width:3px
style guardianActor stroke:#050,stroke-width:2px
style governanceActor stroke:#050,stroke-width:2px
```

## Contract architecture

```mermaid
---
config:
  layout: elk
---
flowchart LR

subgraph OllaGov[Olla Governance]
    ollaGov["OllaGovernance (timelock)"]
end

subgraph OllaVaultGroup["Olla Vault (user-facing)"]
    vault["OllaVault (ERC-7540)"]
    stAztec[StAztec]
    withdrawQ[WithdrawalQueue]
    safety[SafetyModule]
end

subgraph OllaCoreGroup["Olla Core (orchestration)"]
    core[OllaCore]
end

subgraph OllaStaking[Olla Staking Components]
    rewards[RewardsVault]
    stkMan[StakingManager]
    spr[StakingProviderRegistry]
end

subgraph AztecContracts[Aztec Contracts]
    rollupRegistry[AztecRollupRegistry]
    rollup["AztecRollup (canonical)"]
end

ollaGov -->|"owner"| vault
ollaGov -->|"owner"| core
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> safety
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> withdrawQ
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> rewards
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> stkMan
ollaGov -. "DEFAULT_ADMIN_ROLE" .-> spr

vault -->|"MINTER + BURNER"| stAztec
vault -->|"CORE_ROLE"| withdrawQ
vault -->|"deposit + withdrawal checks"| safety
vault -.->|"view: totalAssets, convertToShares, convertToAssets, exchangeRate"| core

core -.->|"view: bufferedAssets, pendingWithdrawalAssets"| vault
core -->|"CORE_ROLE: transferToStaking, receiveUnstaked, finalizeWithdrawals"| vault
core -->|"checkQueueRatio / checkRateDrop / checkAccountingLiveness"| safety

core -->|"stake / unstake / harvestRewards / getUnstakedFunds"| stkMan
core -->|"recordBalance / balance"| rewards

stkMan -->|"getAttesterKeystore"| spr
stkMan -->|"deposit / initiateWithdraw / finalizeWithdraw"| rollup
stkMan -->|"claimSequencerRewards"| rollup
stkMan -->|"getCanonicalRollup"| rollupRegistry
rollupRegistry --> rollup
rollup -->|"rewards AZTEC"| rewards

style ollaGov stroke:#090,stroke-width:3px
style vault stroke:#09f,stroke-width:4px
style stAztec stroke:#09f,stroke-width:3px
style withdrawQ stroke:#090,stroke-width:3px
style safety stroke:#090,stroke-width:3px
style core stroke:#090,stroke-width:4px
style rewards stroke:#090,stroke-width:3px
style stkMan stroke:#090,stroke-width:3px
style spr stroke:#090,stroke-width:3px
style rollup stroke:#ff6,stroke-width:2px
style rollupRegistry stroke:#ff6,stroke-width:2px
```

## Accounting and pricing data flow

```mermaid
flowchart TB

subgraph CoreState["Core owns accounting state"]
    coreStorage["stakedPrincipal<br/>claimableRewards<br/>rewardsVaultBalance<br/>slashingDelta<br/>rewardsDelta<br/>cumulativeRewards<br/>flowCounters<br/>latestReport"]
end

subgraph VaultState["Vault owns buffer and queue state"]
    vaultStorage["bufferedAssets<br/>pendingWithdrawalAssets<br/>operatorApprovals<br/>requestTracking"]
end

subgraph TotalAssets["Core.totalAssets computation"]
    formula["vault.bufferedAssets<br/>+ stakedPrincipal<br/>+ rewardsVaultBalance<br/>+ claimableRewards<br/>- slashingDelta<br/>- vault.pendingWithdrawalAssets"]
end

vaultStorage -.->|"view call"| formula
coreStorage -->|"local read"| formula

subgraph VaultPricing["Vault uses Core for pricing"]
    pricing["deposit: shares = core.convertToShares(assets)<br/>requestRedeem: assets = core.convertToAssets(shares)"]
end

formula -->|"core.totalAssets"| pricing

style coreStorage stroke:#090,stroke-width:3px
style vaultStorage stroke:#09f,stroke-width:3px
style formula stroke:#f90,stroke-width:2px
style pricing stroke:#09f,stroke-width:2px
```

## User flows: deposit

```mermaid
sequenceDiagram
    participant User
    participant Vault as OllaVault
    participant Core as OllaCore
    participant stAztec as StAztec
    participant Safety as SafetyModule

    User->>Vault: deposit(assets, receiver, minSharesOut)
    Vault->>Core: convertToShares(assets) [view]
    Core->>Vault: bufferedAssets() [view]
    Core-->>Vault: shares
    Vault->>Safety: checkDepositAllowed(assets, totalAssets)
    Vault->>Vault: transferFrom(user, vault, assets)
    Vault->>Vault: bufferedAssets += assets
    Vault->>stAztec: mint(receiver, shares)
    Vault-->>User: shares
```

## User flows: async withdrawal

```mermaid
sequenceDiagram
    participant User
    participant Vault as OllaVault
    participant Core as OllaCore
    participant stAztec as StAztec
    participant WQ as WithdrawalQueue
    participant Safety as SafetyModule

    Note over User,Safety: REQUEST
    User->>Vault: requestRedeem(shares, receiver)
    Vault->>Core: convertToAssets(shares) [view]
    Core-->>Vault: assetsExpected
    Vault->>Safety: checkWithdrawalMinimum(shares)
    Vault->>stAztec: burn(user, shares)
    Vault->>WQ: requestWithdrawal(receiver, shares, assetsExpected)
    Vault->>Vault: pendingWithdrawalAssets += assetsExpected

    Note over User,Safety: CLAIM (after rebalance finalizes the request)
    User->>Vault: claimRedeem(requestId)
    Vault->>WQ: claimWithdrawal(requestId)
    Vault->>Vault: bufferedAssets -= assetsExpected
    Vault->>Vault: pendingWithdrawalAssets -= assetsExpected
    Vault->>User: transfer(assets)
```

## Rebalance flow

```mermaid
sequenceDiagram
    participant Anyone
    participant Core as OllaCore
    participant Vault as OllaVault
    participant SM as StakingManager
    participant RV as RewardsVault
    participant Safety as SafetyModule

    Anyone->>Core: rebalance()

    Note over Core: Step 1 - Harvest
    Core->>SM: harvestRewards()
    Core->>RV: recordBalance(expectedRewards)

    Note over Core: Step 2 - PullUnstaked
    Core->>SM: getUnstakedFunds()
    Core->>Vault: receiveUnstaked(amount)

    Note over Core: Step 3 - FinalizeWithdrawals
    Core->>Vault: bufferedAssets() [view]
    Core->>Vault: finalizeWithdrawals(availableAssets)

    Note over Core: Step 4 - InitiateUnstake
    Core->>Vault: bufferedAssets() [view]
    Core->>SM: unstake(deficit)

    Note over Core: Step 5 - StakeSurplus
    Core->>Vault: bufferedAssets() [view]
    Core->>Vault: transferToStaking(surplus)
    Core->>SM: stake(surplus)

    Note over Core: Step 6 - ComputeAttesterState
    Core->>SM: computeAttesterState()

    Note over Core: Step 7 - UpdateAccounting
    Core->>Vault: bufferedAssets() [view]
    Core->>Vault: pendingWithdrawalAssets() [view]
    Core->>SM: totalStaked() / getSlashingDelta()
    Core->>RV: balance()
    Core->>Core: store accounting state
    Core->>Safety: checkRateDrop
    Core->>Safety: checkQueueRatio
    Core->>Safety: checkAccountingLiveness
```

## Role model

```mermaid
flowchart TB

subgraph StAztecRoles[StAztec Roles]
    stAztec_minter["MINTER_ROLE --> OllaVault"]
    stAztec_burner["BURNER_ROLE --> OllaVault"]
end

subgraph VaultRoles[OllaVault Roles]
    vault_core["CORE_ROLE --> OllaCore"]
    vault_gov["owner --> OllaGovernance"]
    vault_guardian["GUARDIAN_ROLE --> Guardian"]
end

subgraph CoreRoles[OllaCore Roles]
    core_gov["owner --> OllaGovernance"]
    core_guardian["GUARDIAN_ROLE --> Guardian"]
    core_operator["OPERATOR_ROLE --> Olla Operator"]
    core_permissionless["rebalance / updateAccounting --> anyone"]
end

subgraph Principles[Key Principles]
    p1["Vault: user-facing interface + share token authority"]
    p2["Core: orchestration + accounting authority + pricing"]
    p3["No contract approves another to pull assets"]
    p4["Vault pushes assets on Core instruction"]
end

style stAztec_minter stroke:#09f
style stAztec_burner stroke:#09f
style vault_core stroke:#090
style core_permissionless fill:#555,color:#fff
style p1 stroke:#f90,stroke-width:2px
style p2 stroke:#f90,stroke-width:2px
style p3 stroke:#f90,stroke-width:2px
style p4 stroke:#f90,stroke-width:2px
```

## fee minting

Core computes protocol fees during `updateAccounting` but only Vault holds the `MINTER_ROLE` on StAztec.

```mermaid
flowchart LR

subgraph OptionA["Option A: Core instructs Vault to mint"]
    coreA[OllaCore] -->|"vault.mintFees(treasury, shares, provider, shares)"| vaultA[OllaVault]
    vaultA -->|"mint(treasury)"| stA1[StAztec]
    vaultA -->|"mint(provider)"| stA1
end

style coreA stroke:#090,stroke-width:3px
style vaultA stroke:#09f,stroke-width:3px
style stA1 stroke:#09f,stroke-width:2px
```
