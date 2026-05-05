# Operator actions

This document summarizes rebalance and accounting flows in Olla Core.

> **Note:** `rebalance()`, `updateAccounting()`, and `refreshAttesterState(address[])` are **permissionless** — anyone can call them. The diagrams below use "Caller" to represent any address. New rebalance cycles are rate-limited by a cooldown (`lastRebalanceTimestamp + rebalanceCooldown`); continuing in-progress cycles has no cooldown.

## Rebalance

### Refresh attester state (separate from rebalance)

```mermaid
sequenceDiagram
    participant A as Anyone
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)

    A->>SM: refreshAttesterState(address[] attesters)
    loop for each attester in array
        SM->>AR: getAttesterView(attester)
        AR-->>SM: status, effectiveBalance, exit, config
        alt Queued + VALIDATING on rollup (entry queue flushed)
            SM->>SM: promote Queued to Active
        end
        alt Queued + NONE on rollup (still in entry queue)
            SM->>SM: no-op, skip
        end
        SM->>SM: delta-update stakedAmount (balance change)
        alt Active + balance decreased + no exit (slashing)
            SM->>SM: slashingDelta += decrease
        end
        alt Active + zombie exit (isRecipient=false)
            SM->>AR: initiateWithdraw(attester, StakingManager)
            SM->>SM: transition to Exiting, track slashing loss
        end
        alt Exiting + exit is exitable
            SM->>AR: finalizeWithdraw(attester)
            AR-->>SM: AZTEC transferred
            SM->>SM: _pendingClaimAmount += exit.amount
            SM->>SM: slashingDelta += (pendingExit - exit.amount) if slashed during delay
        end
        alt Exiting + no exit record (externally finalized)
            SM->>SM: _pendingClaimAmount += pendingExitAmount (stale, conservative)
        end
        alt Active + NONE + zero balance (externally fully exited)
            SM->>SM: remove attester
        end
    end
```

### Purge failed queue entry (permissionless)

If `deposit()` adds an attester to the rollup's entry queue but `flushEntryQueue()` later fails (invalid BLS proof, duplicate key), the attester gets stuck as Queued in StakingManager with inflated `stakedAmount`. This function detects and cleans up that state.

```mermaid
sequenceDiagram
    participant A as Anyone
    participant SM as StakingManager
    participant AR as AztecRollup

    A->>SM: purgeFailedQueueEntry(attester)
    SM->>SM: verify attester is Queued in local registry
    SM->>AR: getAttesterView(attester)
    AR-->>SM: Status.NONE, no balance, no exit
    SM->>AR: getEntryQueueLength()
    AR-->>SM: queue length
    loop scan entry queue
        SM->>AR: getEntryQueueAt(i)
        AR-->>SM: queued attester address
        SM->>SM: revert if target attester still in queue
    end
    SM->>SM: correct stakedAmount, remove attester
    SM->>SM: emit FailedQueueEntryPurged
```

### Harvest rewards

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant SM as StakingManager
    participant RR as AztecRollupRegistry
    participant AR as AztecRollup (canonical)
    participant RA as RewardsAccumulator

    A->>C: rebalance()
    Note over C: Step 1: Harvest rewards
    C->>SM: harvestRewards()
    SM->>RR: getCanonicalRollup()
    RR-->>SM: rollup address
    SM->>AR: claimSequencerRewards(coinbase=RewardsAccumulator)
    AR-->>RA: AZTEC transferred
    C->>RA: recordBalance()
    RA-->>C: rewardsDelta
    C->>RA: withdrawToCore()
    RA-->>C: rewards transferred
```

### Pull unstaked funds

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant SM as StakingManager
    participant V as OllaVault

    A->>C: rebalance()
    Note over C: Step 2: Pull unstaked funds
    C->>SM: getUnstakedFunds()
    SM-->>C: (received, exitAmount)
    Note right of SM: transfers min(balance, exitAmount + refundAmount) to core
    Note right of SM: exitAmount = _pendingClaimAmount (reset to 0)
    Note right of SM: refundAmount = _pendingRefundAmount (reset to 0)
    C->>V: safeTransfer(asset, received) + receiveUnstaked(received)
    Note right of V: vault increments _bufferedAssets and emits UnstakedAssetsReceived
    C->>C: stakedPrincipal -= exitAmount
    Note right of C: donations (received > exitAmount + refundAmount) increase buffer without reducing stakedPrincipal
```

### Process user withdrawal requests

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant SAF as SafetyModule
    participant V as OllaVault

    Note over A,V: Users have existing redemption requests in OllaVault's FIFO queue
    Note over A,V: Vault already has liquidity buffered

    A->>C: rebalance()
    Note over C: Step 3: Finalize withdrawals
    C->>V: bufferedAssets()
    V-->>C: available
    C->>V: pendingWithdrawalAssets()
    V-->>C: queued
    C->>SAF: checkQueueRatio(queued, totalAssets)
    C->>V: finalizeWithdrawals(available, currentRate, maxRequestId)
    V-->>C: (finalizedAmount, finalizedCount)
    Note right of V: payout = shares * min(currentRate, lockedRate) / 1e18
    Note right of V: adjusts assetsExpected down if slashing occurred
    Note right of V: bufferedAssets and pendingWithdrawal* updated internally
```

### Initiate unstake

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant V as OllaVault
    participant SM as StakingManager

    A->>C: rebalance()
    Note over C: Step 4: Initiate unstake
    Note over C: Recomputes unstakeRemaining from current state
    C->>V: pendingWithdrawalAssets()
    V-->>C: pending
    C->>V: bufferedAssets()
    V-->>C: currentBuffer
    C->>SM: pendingUnstakes()
    SM-->>C: pendingUnstakes
    C->>SM: claimableUnstakedFunds()
    SM-->>C: claimable
    C->>C: pendingIncoming = pendingUnstakes + claimable
    C->>C: amountToUnstake = max(0, (pending - currentBuffer) - pendingIncoming)
    C->>SM: unstake(amountToUnstake)
    Note right of C: emit UnstakeInitiated(requested, initiated)
```

### Stake surplus

```mermaid
sequenceDiagram
    participant A as Caller
    participant C as OllaCore
    participant V as OllaVault
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)

    A->>C: rebalance()
    Note over C: Step 5: Stake surplus
    Note over C: Recomputes stakeRemaining from current state
    C->>V: pendingWithdrawalAssets()
    V-->>C: pending
    C->>V: bufferedAssets()
    V-->>C: currentBuffer
    C->>C: stakeable = max(0, currentBuffer - pending)
    C->>V: transferToCore(stakeable)
    V-->>C: assets
    C->>SM: stake(stakeable)
    SM->>AR: deposit()
    SM-->>C: actualStaked
    C->>C: stakedPrincipal += actualStaked
    Note right of C: If buffer insufficient (concurrent redemption), returns 0 gracefully
```

### Rebalance (full flow)

```mermaid
sequenceDiagram
    participant A as Anyone
    participant C as OllaCore
    participant V as OllaVault
    participant SAF as SafetyModule
    participant SM as StakingManager
    participant AR as AztecRollup (canonical)
    participant RA as RewardsAccumulator

    Note over A,SM: Pre-step: refresh attester state (optional, can be separate tx)
    A->>SM: refreshAttesterState(address[] attesters)
    Note right of SM: delta-updates aggregate state + finalizes exits

    A->>C: rebalance()
    Note over C: Cooldown gate: block.timestamp - lastRebalanceTimestamp >= rebalanceCooldown

    Note over C: Step 1: Harvest rewards
    C->>SM: harvestRewards()
    SM->>AR: claimSequencerRewards()
    AR-->>RA: rewards transferred
    C->>RA: recordBalance()
    RA-->>C: rewardsDelta
    C->>RA: withdrawToCore()
    RA-->>C: rewards transferred

    Note over C: Step 2: Pull unstaked funds
    C->>SM: getUnstakedFunds()
    SM-->>C: (received, exitAmount)
    C->>V: receiveUnstaked(received)
    C->>C: stakedPrincipal -= exitAmount

    Note over C: Step 3: Finalize withdrawals
    C->>V: bufferedAssets()
    V-->>C: available
    C->>V: pendingWithdrawalAssets()
    V-->>C: queued
    C->>SAF: checkQueueRatio(queued, totalAssets)
    C->>V: finalizeWithdrawals(available, currentRate, maxRequestId)
    V-->>C: (finalizedAmount, finalizedCount)
    Note right of V: payout = shares * min(currentRate, lockedRate) / 1e18

    Note over C: Step 4: Initiate unstake (recomputed from current state)
    C->>V: pendingWithdrawalAssets()
    V-->>C: pending
    C->>V: bufferedAssets()
    V-->>C: currentBuffer
    C->>SM: pendingUnstakes() + claimableUnstakedFunds()
    SM-->>C: pendingIncoming
    C->>C: amountToUnstake = max(0, (pending - currentBuffer) - pendingIncoming)
    C->>SM: unstake(amountToUnstake)

    Note over C: Step 5: Stake surplus (recomputed from current state)
    loop while stakeable > 0 and gas remaining
        C->>V: pendingWithdrawalAssets() / bufferedAssets()
        V-->>C: pending / currentBuffer
        C->>C: stakeable = max(0, currentBuffer - pending)
        C->>V: transferToCore(stakeable)
        C->>SM: stake(stakeable)
        SM->>AR: deposit()
        C->>C: stakedPrincipal += actualStaked
    end

    Note over C: On completion:
    C->>C: lastRebalanceTimestamp = block.timestamp
    C->>C: _updateAccountingInternal()
```

### Rebalance cooldown and state machine

```mermaid
sequenceDiagram
    participant A as Anyone
    participant C as OllaCore
    participant G as Core Guardian

    A->>C: rebalance()
    Note right of C: Cooldown check: elapsed >= rebalanceCooldown
    Note right of C: (uses lastRebalanceTimestamp, not _latestReport.timestamp)
    Note right of C: executes step machine (Harvest->...->Done)
    C-->>A: returns partial progress when gas low

    Note over A,C: Anyone can continue in-progress cycle (no cooldown)
    A->>C: rebalance()
    Note right of C: step != Done, skips cooldown gate

    Note over C: On completion: lastRebalanceTimestamp = block.timestamp
    Note over C: updateAccounting() does NOT reset cooldown

    opt core guardian override
        G->>C: forceRebalanceReset()
        Note right of C: resets state machine to Done
        Note right of C: resets lastRebalanceTimestamp (enforces cooldown from reset)
        Note right of C: default holder is OllaGovernance, so this is timelocked unless a separate Core guardian is granted
    end
```

## Accounting

```mermaid
sequenceDiagram
    participant A as Anyone
    participant C as OllaCore
    participant V as OllaVault
    participant SAF as SafetyModule
    participant SM as StakingManager
    participant RA as RewardsAccumulator
    participant ST as StAztec

    A->>C: updateAccounting()
    Note right of C: permissionless, requires rebalance step == Done
    C->>SAF: checkAccountingLiveness()
    C->>SM: getClaimableRewards()
    C->>SM: getSlashingDelta()
    C->>SM: totalStaked()
    C->>RA: balance()
    C->>V: mintFees(treasury, treasuryShares, provider, providerShares)
    V->>ST: mint(treasury/provider fee shares)
    C->>V: pendingWithdrawalAssets()
    V-->>C: queued
    C->>SAF: checkQueueRatio(queued, newTotalAssets)
    C->>SAF: checkRateDrop(oldRate, nextRate)
    C->>SAF: setLatestAccountingTimestamp(block.timestamp)
    Note right of C: updates _latestReport.timestamp (reporting only)
    Note right of C: does NOT update lastRebalanceTimestamp (cooldown unaffected)
    Note right of C: emits AccountingUpdated + AttestersStateRead
```
