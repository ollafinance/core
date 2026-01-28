# Architecture and Flows

## Top-level diagram

```mermaid
flowchart LR

subgraph "Actors / Roles"
    user[User]
    governanceMultisig[Governance/Admin multisig]
    guardianMultisig[Guardian multisig]
    operatorKey[Operator key/bot]
    providerAdmin[Staking provider admin]
    treasuryMultisig[Treasury multisig]
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
core -->|"withdrawToCore()"| rewards
rewards -->|"AZTEC rewards"| core

core -->|"finalizeWithdrawals(available)"| withdrawQ

core -->|"stake(amount) / unstake(amount)"| stkMan
core -->|"cleanActivatedAttesters() / getUnstakedFunds()"| stkMan
stkMan -->|"deposit(...)"| rollup
stkMan -->|"initiateWithdraw(...) / finalizeWithdraw(attester)"| rollup
rollup -->|"AZTEC (unstaked)"| stkMan
stkMan -->|"AZTEC"| core

core -->|"mint(governance, treasuryShares)"| stAztec
core -->|"mint(providerRewardsRecipient, providerShares)"| stAztec
stAztec -->|"stAztec fees"| treasuryMultisig
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
style treasuryMultisig stroke:#050,stroke-width:2px
style guardianMultisig stroke:#050,stroke-width:2px
style governanceMultisig stroke:#050,stroke-width:2px
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
