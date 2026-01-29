# Architecture and Flows

## Top-level diagram

```mermaid
flowchart LR

subgraph "Actors / Roles"
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
user -->|"deposit > Aztec < transferFrom(user, core, assets)"| core
core -->|"deposit > StAztec < mint(recipient, shares)"| user

user -->|"requestRedeem(shares, recipient)"| core
core -->|"withdrawal > StAztec < burn(owner, shares)"| user
core -->|"requestWithdrawal(recipient, shares, assetsExpected, rate)"| withdrawQ

user -->|"claimRequestById(requestId)"| core
core -->|"claimWithdrawal(requestId)"| withdrawQ
core -->|"withdrawal payout > Aztec < transferFrom(core, user, assetsExpected)"| user

%% Safety checks (control-plane)
core -->|"checkDepositAllowed / checkWithdrawalMinimum"| safety
core -->|"checkQueueRatio / checkAccountingLiveness"| safety

%% Operator cycle (end-state orchestration)
operatorKey -->|"rebalance()"| core
operatorKey -->|"harvestRewards()"| core
operatorKey -->|"finalizeWithdrawals(available)"| core
operatorKey -->|"updateAccounting()"| core

%% Staking principal (AZTEC token) movements
core -->|"stake > Aztec < transferFrom(core, StakingManager, stakeAmount)"| stkMan
stkMan -->|"deposit > Aztec < transferFrom(StakingManager, AztecRollup, stakeAmount)"| rollup

core -->|"unstake(amount)"| stkMan
stkMan -->|"initiateWithdraw"| rollup

core -->|"claimUnstakedFunds > Aztec < transferFrom(StakingManager, core, unstakedAmount)"| stkMan
stkMan -->|"finalizeWithdraw > Aztec < transferFrom(rollup, StakingManager, unstakedAmount)"| rollup

core -->|"harvestRewards()"| stkMan
stkMan -->|"getCanonicalRollup()"| rollupRegistry
rollupRegistry -->|"canonical rollup"| rollup
stkMan -->|"claimSequencerRewards(coinbase=rewardsVault)"| rollup
rollup -->|"rewards > Aztec < transferFrom(rollup, rewardsVault, amount)"| rewards
core -->|"recordRewards(expectedRewards)"| rewards

core -->|"finalizeWithdrawals(available)"| withdrawQ

core -->|"balance()"| rewards

core -->|"pay staking fees > StAztec < mint(governance, treasuryShares)"| governanceMultisig
core -->|"pay staking fees > StAztec < mint(providerRewardsRecipient, providerShares)"| providerRewardsRecipient

style user fill:#900
style operatorKey fill:#090
style providerAdmin fill:#009
style rollup stroke:#ff6,stroke-width:2px
style core stroke:#090,stroke-width:4px
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
    participant SAF as SafetyModule
    participant AZ as AssetToken
    participant ST as StAztec

    U->>C: deposit(assets, recipient)
    C->>SAF: isPaused()
    SAF-->>C: false
    C->>SAF: checkDepositAllowed(assets, totalAssets)
    SAF-->>C: true
    C->>C: shares = convertToShares(assets)
    C->>C: bufferedAssets += assets
    U->>AZ: approve(C, assets)
    C->>AZ: transferFrom(U, C, assets)
    C->>C: syncBufferedWithBalance()
    C->>ST: mint(to=recipient, amount=shares)
    ST-->>U: stAztec balance updated
```

### Withdrawal

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant SAF as SafetyModule
    participant ST as StAztec
    participant WQ as WithdrawalQueue
    participant AZ as AssetToken

    Note over U,C: Phase 1 - user requests withdrawal

    U->>C: requestRedeem(shares, recipient)
    C->>C: require no active request for U
    C->>C: rate = exchangeRate
    C->>C: assetsExpected = shares * rate / 1e18
    C->>SAF: checkWithdrawalMinimum(shares)
    C->>WQ: nextRequestId()
    C->>ST: burn(owner=U, amount=shares)
    C->>WQ: requestWithdrawal(recipient, shares, assetsExpected, rate)
    WQ->>WQ: enqueue withdrawalRequest (FIFO)

    Note over U,WQ: Phase 2 - later, after liquidity and operator action

    U->>C: claimRequestById(requestId)
    C->>WQ: claimWithdrawal(requestId)
    WQ-->>C: assetsClaimed
    Note right of C: require assetsClaimed == assetsExpected
    C->>AZ: transfer(recipient, assetsExpected)
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
    participant SAF as SafetyModule
    participant WQ as WithdrawalQueue

    Note over OP,WQ: User has an existing withdrawalRequest in FIFO queue
    Note over OP,WQ: Core already has liquidity buffered

    OP->>C: finalizeWithdrawals(available)
    C->>SAF: checkQueueRatio(queued, total)
    Note right of C: queued = WQ.totalPendingAssets()
    Note right of C: total = C.totalAssets()
    C->>C: syncBufferedWithBalance()
    C->>C: require available <= bufferedAssets
    C->>WQ: previewFinalizeWithdrawals(available)
    WQ-->>C: used
    C->>WQ: finalizeWithdrawals(available)
    WQ-->>C: finalized
    Note right of C: require finalized == used
```

#### Update accounting

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SAF as SafetyModule
    participant SM as StakingManager
    participant RV as RewardsVault
    participant WQ as WithdrawalQueue
    participant ST as StAztec

    OP->>C: updateAccounting()
    C->>SAF: checkAccountingLiveness()
    C->>SM: getClaimableRewards()
    C->>SM: getSlashingDelta()
    C->>SM: totalStaked()
    C->>RV: balance()
    C->>ST: mint(governance/provider fee shares)
    C->>WQ: totalPendingAssets()
    C->>SAF: checkQueueRatio(queued, newTotalAssets)
    C->>SAF: checkRateDrop(oldRate, nextRate)
    C->>SAF: setLatestAccountingTimestamp(block.timestamp)
    Note right of C: emits AccountingUpdated + AttestersStateRead
```
