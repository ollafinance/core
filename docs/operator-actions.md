# Operator actions

This document summarizes rebalance and accounting flows in Olla Core.

> **Note:** `rebalance()`, `updateAccounting()`, and `refreshAttesterState(address[])` are **permissionless** — anyone can call them. The diagrams below use "Caller" to represent any address. New rebalance cycles are rate-limited by a cooldown (`_lastRebalanceTimestamp + rebalanceCooldown`); continuing in-progress cycles has no cooldown.

## Rebalance

### Refresh attester state (separate from rebalance)

```mermaid
sequenceDiagram
    participant A as Anyone
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)

    A->>SM: refreshAttesterState(address[] attesters)
    loop for each attester in array
        SM->>AR: getInfo(attester)
        AR-->>SM: attester state
        SM->>SM: delta-update _aggregateState
        alt attester is exitable
            SM->>AR: finalizeWithdraw(attester)
            AR-->>SM: AZTEC transferred
            SM->>SM: _pendingClaimAmount += finalized
        end
    end
```

### Harvest rewards

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant SM as StakingManager
    participant RR as AztecRollupRegistry
    participant AR as AztecRollup (canonical)
    participant RV as RewardsVault

    A->>C: rebalance()
    Note over C: Step 1: Harvest rewards
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
    participant A as Caller
    participant C as OllaCore
    participant SM as StakingManager

    A->>C: rebalance()
    Note over C: Step 2: Pull unstaked funds
    C->>SM: getUnstakedFunds()
    SM-->>C: (received, exitAmount, hasRemainingExits)
    Note right of SM: sweeps full balance to core
    Note right of SM: exitAmount = _pendingClaimAmount (reset to 0)
    C->>C: bufferedAssets += received
    C->>C: stakedPrincipal -= exitAmount
    Note right of C: donations (received > exitAmount) increase buffer without reducing stakedPrincipal
```

### Process user withdrawal requests

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant SAF as SafetyModule
    participant WQ as WithdrawalQueue

    Note over A,WQ: User has an existing withdrawalRequest in FIFO queue
    Note over A,WQ: Core already has liquidity buffered

    A->>C: rebalance()
    Note over C: Step 3: Finalize withdrawals
    C->>SAF: checkQueueRatio(queued, total)
    Note right of C: queued = WQ.totalPendingAssets()
    Note right of C: total = C.totalAssets()
    C->>C: syncBufferedWithBalance()
    Note right of C: available = bufferedAssets
    C->>WQ: previewFinalizeWithdrawals(available)
    WQ-->>C: used
    C->>WQ: finalizeWithdrawals(available)
    WQ-->>C: finalized
    Note right of C: require finalized == used
```

### Initiate unstake

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant WQ as WithdrawalQueue
    participant SM as StakingManager

    A->>C: rebalance()
    Note over C: Step 4: Initiate unstake
    Note over C: Recomputes unstakeRemaining from current state
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
    participant A as Caller
    participant C as OllaCore
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)

    A->>C: rebalance()
    Note over C: Step 5: Stake surplus
    Note over C: Recomputes stakeRemaining from current state
    C->>C: stakeable = bufferedAssets - targetBufferedAssets
    C->>SM: stake(stakeable)
    SM->>AR: stake()
    C->>C: bufferedAssets -= stakedAmount
    C->>C: stakedPrincipal += stakedAmount
    Note right of C: If buffer insufficient (concurrent redemption), returns 0 gracefully
```

### Rebalance (full flow)

```mermaid
sequenceDiagram
    participant A as Anyone
    participant C as OllaCore
    participant SAF as SafetyModule
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)
    participant RV as RewardsVault
    participant WQ as WithdrawalQueue

    Note over A,SM: Pre-step: refresh attester state (optional, can be separate tx)
    A->>SM: refreshAttesterState(address[] attesters)
    Note right of SM: delta-updates aggregate state + finalizes exits

    A->>C: rebalance()
    Note over C: Cooldown gate: block.timestamp - _lastRebalanceTimestamp >= rebalanceCooldown

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
    SM-->>C: (received, exitAmount, hasRemainingExits)
    C->>C: bufferedAssets += received
    C->>C: stakedPrincipal -= exitAmount

    Note over C: Step 3: Finalize withdrawals
    C->>C: available = bufferedAssets
    C->>WQ: totalPendingAssets()
    C->>SAF: checkQueueRatio(queued, totalAssets)
    C->>WQ: previewFinalizeWithdrawals(available)
    C->>WQ: finalizeWithdrawals(available)
    WQ-->>C: amountUsed
    C->>C: bufferedAssets -= amountUsed

    Note over C: Step 4: Initiate unstake (recomputed from current state)
    C->>WQ: totalPendingAssets()
    C->>C: requiredBuffer = max(pending, targetBufferedAssets)
    C->>C: amountToUnstake = max(0, requiredBuffer - buffered)
    C->>SM: pendingUnstakes()
    SM-->>C: pendingUnstakes
    C->>SM: unstake(initiated)

    Note over C: Step 5: Stake surplus (recomputed from current state)
    C->>C: stakeable = bufferedAssets - targetBufferedAssets
    loop while stakeable > 0 and gas remaining
        C->>SM: stake(stakeable)
        SM->>AR: stake()
        C->>C: bufferedAssets -= stakedAmount
        C->>C: stakedPrincipal += stakedAmount
    end

    Note over C: On completion:
    C->>C: _lastRebalanceTimestamp = block.timestamp
    C->>C: _updateAccountingInternal()
```

### Rebalance cooldown and state machine

```mermaid
sequenceDiagram
    participant A as Anyone
    participant C as OllaCore
    participant G as Guardian

    A->>C: rebalance()
    Note right of C: Cooldown check: elapsed >= rebalanceCooldown
    Note right of C: (uses _lastRebalanceTimestamp, not _latestReport.timestamp)
    Note right of C: executes step machine (Harvest->...->Done)
    C-->>A: returns partial progress when gas low

    Note over A,C: Anyone can continue in-progress cycle (no cooldown)
    A->>C: rebalance()
    Note right of C: step != Done, skips cooldown gate

    Note over C: On completion: _lastRebalanceTimestamp = block.timestamp
    Note over C: updateAccounting() does NOT reset cooldown

    opt guardian override
        G->>C: forceRebalanceReset()
        Note right of C: resets state machine to Done
        Note right of C: does NOT reset _lastRebalanceTimestamp
    end
```

## Accounting

```mermaid
sequenceDiagram
    participant A as Anyone
    participant C as OllaCore
    participant SAF as SafetyModule
    participant SM as StakingManager
    participant RV as RewardsVault
    participant WQ as WithdrawalQueue
    participant ST as StAztec

    A->>C: updateAccounting()
    Note right of C: permissionless, requires rebalance step == Done
    C->>SAF: checkAccountingLiveness()
    C->>SM: getClaimableRewards()
    C->>SM: getSlashingDelta()
    C->>SM: totalStaked()
    C->>RV: balance()
    C->>ST: mint(treasury/provider fee shares)
    C->>WQ: totalPendingAssets()
    C->>SAF: checkQueueRatio(queued, newTotalAssets)
    C->>SAF: checkRateDrop(oldRate, nextRate)
    C->>SAF: setLatestAccountingTimestamp(block.timestamp)
    Note right of C: updates _latestReport.timestamp (reporting only)
    Note right of C: does NOT update _lastRebalanceTimestamp (cooldown unaffected)
    Note right of C: emits AccountingUpdated + AttestersStateRead
```
