# Architecture and Flows

## Top-level diagram

```mermaid
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
    governanceAdminWallet -->|"DEFAULT_ADMIN_ROLE for all contracts"| governanceAdminWallet
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
    C->>RV: recordBalance()
    RV-->>C: rewardsDelta
```

#### Pull unstaked funds

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SM as StakingManager
    participant AZ as AssetToken

    OP->>SM: computeAttesterState()
    Note right of SM: syncs attester states + caches staking data
    OP->>C: rebalance()
    Note over C: Step 2: Pull unstaked funds
    C->>SM: getUnstakedFunds()
    SM-->>C: transfer matured unstakes
    C->>AZ: balanceOf(C) increases
    C->>C: bufferedAssets += received
    Note right of C: emit UnstakedFundsClaimed(received)
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
    Note right of C: available = bufferedAssets
    C->>C: require available <= bufferedAssets
    C->>WQ: previewFinalizeWithdrawals(available)
    WQ-->>C: used
    C->>WQ: finalizeWithdrawals(available)
    WQ-->>C: finalized
    Note right of C: require finalized == used
```

#### Initiate unstake

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant WQ as WithdrawalQueue
    participant SM as StakingManager

    OP->>C: rebalance()
    Note over C: Step 4: Initiate unstake
    Note over C: Trigger when requested > pendingUnstakes
    C->>WQ: totalPendingAssets()
    C->>C: requiredBuffer = max(pending, targetBufferedAssets)
    C->>C: amountToUnstake = max(0, requiredBuffer - buffered)
    C->>SM: pendingUnstakes()
    SM-->>C: pendingUnstakes
    C->>C: initiated = requested
    C->>SM: unstake(initiated)
    Note right of C: emit UnstakeInitiated(requested, initiated)
```

#### Stake surplus

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)

    OP->>C: rebalance()
    Note over C: Step 5: Stake surplus
    C->>C: stakeable = bufferedAssets - targetBufferedAssets
    C->>SM: stake(stakeable)
    SM->>AR: stake()
    C->>C: bufferedAssets -= stakedAmount
    C->>C: stakedPrincipal += stakedAmount
```

#### Rebalance (full flow)

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SAF as SafetyModule
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)
    participant RV as RewardsVault
    participant WQ as WithdrawalQueue

    OP->>SM: computeAttesterState()
    Note right of SM: syncs attester states + caches staking data
    OP->>C: rebalance()

    Note over C: Step 1: Harvest rewards
    C->>SM: harvestRewards()
    SM->>AR: claimSequencerRewards()
    AR-->>RV: rewards transferred
    C->>RV: recordBalance()
    RV-->>C: rewardsDelta

    Note over C: Step 2: Pull unstaked funds
    C->>SM: getUnstakedFunds()
    SM-->>C: transfer matured unstakes
    C->>C: bufferedAssets += received

    Note over C: Step 3: Finalize withdrawals
    C->>C: available = bufferedAssets
    C->>WQ: totalPendingAssets()
    C->>SAF: checkQueueRatio(queued, totalAssets)
    C->>WQ: previewFinalizeWithdrawals(available)
    C->>WQ: finalizeWithdrawals(available)
    WQ-->>C: amountUsed
    C->>C: bufferedAssets -= amountUsed

    Note over C: Step 4: Initiate unstake
    C->>WQ: totalPendingAssets()
    C->>C: requiredBuffer = max(pending, targetBufferedAssets)
    C->>C: amountToUnstake = max(0, requiredBuffer - buffered)
    C->>SM: pendingUnstakes()
    SM-->>C: pendingUnstakes
    C->>SM: unstake(initiated)

    Note over C: Step 5: Stake surplus
    C->>C: stakeable = bufferedAssets - targetBufferedAssets
    loop while stakeable >= VALIDATOR_STAKE_UNIT
        C->>SM: stake(VALIDATOR_STAKE_UNIT)
        SM->>AR: stake()
        C->>C: bufferedAssets -= unit
        C->>C: stakedPrincipal += unit
        C->>C: stakeable -= unit
    end
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

    OP->>SM: computeAttesterState()
    Note right of SM: syncs attester states + caches staking data
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
