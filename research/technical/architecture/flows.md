# Architecture and Flows

## Top-level diagram

```mermaid
flowchart LR
    protocolOperator -.PROTOCOL_OPERATOR_ROLE.- protocolOperator
    nodeOperator -.STAKING_PROVIDER_ADMIN_ROLE.- nodeOperator
    guardianMultisig -.GUARDIAN_ROLE.- guardianMultisig
    guardianMultisig -.DEFAULT_ADMIN_ROLE.- guardianMultisig
    linkStyle 0,1,2,3 stroke:#c0392b,stroke-width:5px,stroke-dasharray: 5 3;

subgraph "Users"
    user[User]
    protocolOperator[Protocol Operator]
    nodeOperator[Node Operator]
    guardianSigner[Guardian Signer]
    treasurySigner[Treasury Signer]
end

    nodeServer["Physical Node Server"]
    nodeRewardsAddress["Node Rewards Address"]
    core["OllaCore"]
    stAztec["stAztec"]

    aztecRollup["AztecRollupContract"]
    rewards["RewardsVault"]
    stkMan["StakingManager"]
    withdrawQ["WithdrawalQueue"]

    treasuryMultisig["Treasury Multisig"]
    treasurySigner -->|signs| treasuryMultisig

    guardianMultisig["Guardian Multisig"]

    guardianSigner -->|signs| guardianMultisig
    guardianMultisig -->|"emergency actions"| core
    guardianMultisig -->|"manage roles"| core

    core -->|"mint on deposit"| stAztec
    core -->|"mint protocol fee"| stAztec
    stAztec --->|"minted stAztec"| treasuryMultisig
    stAztec --->|"minted stAztec"| nodeRewardsAddress
    core -->|"burn on withdrawal request"| stAztec

    protocolOperator -->|"rebalance: stake, unstake, claim, compound, finalize"| core
    protocolOperator -->|update accounting| core

    user -->|"deposit Aztec for stAztec"| core

    user -->|"requestWithdrawal"| core
    core -->|"create withdrawal request - lock rate"| withdrawQ
    core -->|"finalize withdrawal requests"| withdrawQ
    core -->|"stake/unstake"| stkMan
    core -->|"getUnstakedFunds"| stkMan
    user -->|"claim finalized withdrawal"| withdrawQ

    nodeOperator -->|owns| nodeRewardsAddress
subgraph STAKING
    nodeOperator -->|"addKeysToProvider"| stkMan
    nodeOperator -->|"dripQueue"| stkMan
    nodeOperator -->|"set reward address"| stkMan
    nodeOperator -->|"configure keys"| nodeServer
    nodeServer -->|"validator produces rewards"| aztecRollup
    stkMan -->|"deposit<br/>(i.e. stake)"| aztecRollup
    stkMan -->|"claimSequencerRewards<br/>(i.e. harvest rewards)"| aztecRollup
    stkMan -->|"initiateWithdraw<br/>(i.e. unstake)"| aztecRollup
    aztecRollup -.->|"AZTEC (withdrawals)"| stkMan
end
    core -->|getClaimableRewards| stkMan
    core -->|harvestRewards| stkMan
    aztecRollup -.->|"AZTEC rewards (coinbase)"| rewards
    core -->|withdrawToCore| rewards

style user fill:#900
style protocolOperator fill:#090
style nodeOperator fill:#009
style nodeServer stroke:#00f,stroke-width:2px,stroke-dasharray: 5
style aztecRollup stroke:#ff6,stroke-width:2px
style core stroke:#090,stroke-width:4px
style stAztec stroke:#090,stroke-width:4px
style rewards stroke:#090,stroke-width:4px
style stkMan stroke:#090,stroke-width:4px
style withdrawQ stroke:#090,stroke-width:4px
style treasuryMultisig stroke:#050,stroke-width:2px
style guardianMultisig stroke:#050,stroke-width:2px
```

## Activity diagrams

### Deposit

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant ST as stAztec

    U->>C: deposit(assets)
    Note right of C: Check SafetyModule<br/>compute shares at exchangeRate
    C->>ST: mint(to=User, amount=shares)
    ST-->>U: stAztec balance updated
```

### Withdrawal

```mermaid
sequenceDiagram
    participant U as User
    participant C as OllaCore
    participant ST as stAztec
    participant WQ as WithdrawalQueue

    Note over U,C: Phase 1 – user requests withdrawal

    U->>C: requestRedeem(shares)
    C->>ST: burn(from=U, amount=shares)
    Note right of C: Compute assetsExpected = shares * exchangeRate
    C->>WQ: requestWithdrawal(user, shares, assetsExpected, rate)
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
    participant AR as AztecRollupContract
    participant RV as RewardsVault

    OP->>C: rebalance
    C->>SM: harvestRewards()
    SM->>AR: claimSequencerRewards(to=RewardsVault)
    AR-->>RV: AZTEC transferred
    AR-->>SM: returns harvestedAmount
    SM->>RV: postReceiveFundsHook(harvestedAmount)
```

#### Process user withdrawal requests

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant stkMan as StakingManager
    participant WQ as WithdrawalQueue
  
    Note over OP,WQ: User has an existing withdrawalRequest in FIFO queue
    Note over OP,WQ: Operator has already unstaked sufficient AZTEC with prev. rebalance

    OP->>C: rebalance
    C->>stkMan: getUnstakedFunds
    stkMan->>C: transfers unstakedFunds

    C->>C: availableForWithdrawals = bufferedAssets + safetyBuffer
    C->>WQ: finalizeWithdrawals(availableForWithdrawals)

    loop while availableForWithdrawals > pendingRequests[0].amount
        WQ->>WQ: pop pendingRequests[0]
        WQ->>WQ: add request to finalized list
    end
    WQ->>C: amountStillNeededForWithdrawals
```

#### Stake available Aztec

```mermaid
sequenceDiagram
    participant OP as Operator
    participant C as OllaCore
    participant SR as StakingManager
    participant AR as AztecRollupContract

    OP->>C: rebalance
    Note over C: targetBuffer is the amount we want to keep liquid for withdrawals
    C->>C: stakeable = bufferedAssets - targetBuffer
    C->>SR: stake(amount = stakeable)
    SR->>AR: getActivationThreshold()
    Note over SR: actualStake = min(amount, activationThreshold * queuedKeys)
    SR->>C: transferFrom(core, actualStake)
    SR->>AR: approve(actualStake)
    loop for each attester to stake
        SR->>AR: deposit(attester,<br/>withdrawer=StakingManager,<br/>BLS keys, moveWithRollup=true)
        AR-->>SR: attester activated
    end
    SR-->>C: stake executed (may be partial)
```

#### Unstake Aztec

```mermaid
sequenceDiagram
    participant op as Operator
    participant C as OllaCore
    participant WQ as WithdrawalQueue
    participant stkMan as StakingManager
    participant AR as AztecRollupContract

    op->>C: rebalance
    C->>WQ: totalPendingAssets
    WQ-->>C: totalPendingAssets
    C->>C: amountToUnstake = max(0, withdrawalRequestsAmount - bufferedAssets)
    C->>stkMan: unstake(amountToUnstake)
    loop over activated attesters until enough
        stkMan->>AR: getAttesterView(attester)
        stkMan->>AR: initiateWithdraw(attester,<br/>withdrawer=StakingManager)
        stkMan->>stkMan: move attester to pendingUnstakeRequests
    end
    Note over stkMan,AR: Later, once exits are exitable
    C->>stkMan: getUnstakedFunds()
    loop for each exitable pending attester
        stkMan->>AR: finalizeWithdraw(attester)
        AR-->>stkMan: AZTEC transferred
    end
    stkMan-->>C: transfer claimed AZTEC
```
