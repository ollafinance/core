# Operator actions

This document summarizes operator flows in Olla Core.

## Rebalance

### Harvest rewards

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
    C->>RV: withdrawToCore()
    RV-->>C: rewards transferred
```

### Pull unstaked funds

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

### Process user withdrawal requests

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

### Initiate unstake

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

### Stake surplus

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

### Rebalance (full flow)

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
    C->>RV: withdrawToCore()
    RV-->>C: rewards transferred

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

### Rebalance pause state machine

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant G as Guardian

    OP->>C: rebalance()
    Note right of C: sets rebalancePaused=true at start
    Note right of C: executes step machine (Harvest->...->Done)
    C-->>OP: returns partial progress when gas low
    Note right of C: sets rebalancePaused=false after completion + accounting update

    opt governance override
        G->>C: forceRebalanceUnpause()
        Note right of C: resets state machine + clears pause
    end
```

## Accounting

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
