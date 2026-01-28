# Architecture and Flows

## Top-level diagram

```mermaid
flowchart LR

subgraph "Actors"
    user[User]
    governanceMultisig[Governance/Admin multisig]
    guardianMultisig[Guardian multisig]
    operatorKey[Operator key/bot]
end

subgraph "StakingProvider"
    providerAdmin[Staking provider admin]
    providerRewardsRecipient[Provider rewards recipient]
end

subgraph "On-chain modules"
    core[OllaCore]
    stAztec[StAztec]
    safety[SafetyModule]
    withdrawQ[WithdrawalQueue]
    rewards[RewardsVault]
    stkMan[StakingManager]
end

subgraph "Aztec"
    rollupRegistry[AztecRollupRegistry]
    rollup["AztecRollup (canonical)"]
end

%% Role bindings (control-plane)
governanceMultisig -. "DEFAULT_ADMIN_ROLE" .-> core
governanceMultisig -. "DEFAULT_ADMIN_ROLE" .-> safety
governanceMultisig -. "DEFAULT_ADMIN_ROLE" .-> rewards
governanceMultisig -. "DEFAULT_ADMIN_ROLE" .-> withdrawQ
governanceMultisig -. "DEFAULT_ADMIN_ROLE" .-> stkMan

guardianMultisig -. "GUARDIAN_ROLE" .-> core
guardianMultisig -. "GUARDIAN_ROLE" .-> safety

operatorKey -. "OPERATOR_ROLE" .-> core
providerAdmin -. "STAKING_PROVIDER_ADMIN_ROLE" .-> stkMan

%% Inter-module authority (control-plane)
core -. "CORE_ROLE" .-> rewards
core -. "CORE_ROLE" .-> withdrawQ
core -. "CORE_ROLE" .-> stkMan

%% User flows (asset + call-path)
user -->|"AZTEC: deposit(assets, recipient)"| core
core -->|"stAztec: mint(recipient, shares)"| stAztec
stAztec -->|"stAztec"| user

user -->|"requestRedeem(shares, recipient)"| core
core -->|"stAztec: burn(owner, shares)"| stAztec
core -->|"requestWithdrawal(recipient, shares, assetsExpected, rate)"| withdrawQ

user -->|"claimRequestById(requestId)"| core
core -->|"claimWithdrawal(requestId)"| withdrawQ
core -->|"AZTEC: transfer(recipient, assetsExpected)"| user

%% Safety checks (control-plane)
core -->|"checkDepositAllowed / checkWithdrawalMinimum"| safety
core -->|"checkQueueRatio / checkAccountingLiveness"| safety

%% Operator cycle (end-state orchestration)
operatorKey -->|"rebalance()"| core
operatorKey -->|"harvestRewards()"| core
operatorKey -->|"finalizeWithdrawals(available)"| core
operatorKey -->|"updateAccounting()"| core

core -->|"harvestRewards()"| stkMan
stkMan -->|"getCanonicalRollup()"| rollupRegistry
rollupRegistry -->|"canonical rollup"| rollup
stkMan -->|"claimSequencerRewards(coinbase=rewardsVault)"| rollup
rollup -->|"AZTEC rewards"| rewards
core -->|"recordRewards(expectedRewards)"| rewards

core -->|"finalizeWithdrawals(available)"| withdrawQ

core -->|"getClaimableRewards / getSlashingDelta / totalStaked"| stkMan
core -->|"balance()"| rewards

core -->|"mint(governance, treasuryShares)"| stAztec
core -->|"mint(providerRewardsRecipient, providerShares)"| stAztec
stAztec -->|"stAztec fees"| governanceMultisig
stAztec -->|"stAztec fees"| providerRewardsRecipient

%% Emphasis
linkStyle 0,1,2,3,4,5,6,7,8,9,10,11 stroke:#c0392b,stroke-width:4px,stroke-dasharray: 5 3;

style user fill:#900
style operatorKey fill:#090
style providerAdmin fill:#009
style rollup stroke:#ff6,stroke-width:2px
style core stroke:#090,stroke-width:4px
style stAztec stroke:#090,stroke-width:4px
style safety stroke:#090,stroke-width:3px
style rewards stroke:#090,stroke-width:3px
style stkMan stroke:#090,stroke-width:3px
style withdrawQ stroke:#090,stroke-width:3px
style rollupRegistry stroke:#ff6,stroke-width:2px
style guardianMultisig stroke:#050,stroke-width:2px
style governanceMultisig stroke:#050,stroke-width:2px
```

## Activity diagrams

### Deposit

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant ST as StAztec

    U->>C: deposit(assets, recipient)
    Note right of C: Check SafetyModule (paused + deposit cap)
    C->>ST: mint(to=recipient, amount=shares)
    ST-->>U: stAztec balance updated
```

### Withdrawal

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant ST as StAztec
    participant WQ as WithdrawalQueue

    Note over U,C: Phase 1 – user requests withdrawal

    U->>C: requestRedeem(shares, recipient)
    Note right of C: checkWithdrawalMinimum(shares)
    Note right of C: assetsExpected = shares * exchangeRate
    C->>ST: burn(owner=U, amount=shares)
    C->>WQ: requestWithdrawal(recipient, shares, assetsExpected, rate)
    WQ->>WQ: enqueue withdrawalRequest (FIFO)

    Note over U,WQ: Phase 2 – later, after liquidity and operator action

    U->>C: claimRequestById(requestId)
    C->>WQ: claimWithdrawal(requestId)
    WQ->>WQ: mark request as claimed
    C->>U: transfer assetsExpected
```

### Rebalance use cases

#### Harvest rewards

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SM as StakingManager
    participant RR as AztecRollupRegistry
    participant AR as AztecRollup (canonical)
    participant RV as RewardsVault

    OP->>C: harvestRewards()
    C->>SM: harvestRewards()
    SM->>RR: getCanonicalRollup()
    RR-->>SM: rollup address
    SM->>AR: claimSequencerRewards(coinbase=RewardsVault)
    AR-->>RV: AZTEC transferred
    AR-->>SM: returns harvestedAmount
    SM-->>C: harvestedAmount
    C->>RV: recordRewards(harvestedAmount)
```

#### Process user withdrawal requests

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SM as SafetyModule
    participant WQ as WithdrawalQueue

    Note over OP,WQ: User has an existing withdrawalRequest in FIFO queue
    Note over OP,WQ: Core already has liquidity buffered (available <= bufferedAssets)

    OP->>C: finalizeWithdrawals(available)
    C->>SM: checkQueueRatio(totalPendingAssets, totalAssets)
    C->>WQ: previewFinalizeWithdrawals(available)
    C->>WQ: finalizeWithdrawals(available)
    WQ-->>C: used
```
