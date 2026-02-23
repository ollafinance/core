# Governance actions

This document summarizes governance and admin flows in Olla Core.

## Configuration

```mermaid
sequenceDiagram
    participant GOV as Governance (admin)
    participant C as OllaCore
    participant SM as StakingManager

    GOV->>C: setProtocolFeeBP(newFee)
    GOV->>C: setTreasuryFeeSplitBP(newSplit)
    GOV->>C: setInstantRedemptionFeeBP(newFee)
    GOV->>C: setTargetBufferedAssets(newBuffer)
    GOV->>C: setRebalanceGasThreshold(newThreshold)
    C->>SM: setGasThreshold(newThreshold)
```

## Roles and safety

### Governance transfer (two-step)

```mermaid
sequenceDiagram
    participant GOV as Current Governance
    participant CORE as OllaCore
    participant NEW as New Governance

    GOV->>CORE: proposeGovernance(newGov)
    CORE-->>GOV: GovernanceProposed(oldGov, newGov)

    NEW->>CORE: acceptGovernance()
    CORE->>CORE: grant roles to newGov
    CORE->>CORE: revoke roles from oldGov
    CORE-->>NEW: GovernanceAccepted(oldGov, newGov)

    opt cancel before accept
        GOV->>CORE: cancelGovernanceProposal()
        CORE-->>GOV: GovernanceProposalCancelled(governance, pendingGovernance)
    end
```

### Safety module circuit breaker

```mermaid
sequenceDiagram
    participant C as OllaCore
    participant SAF as SafetyModule
    participant GOV as Governance (admin)
    participant G as Guardian

    Note over C,SAF: Core triggers breaker checks
    C->>SAF: checkRateDrop(oldRate, nextRate)
    C->>SAF: checkQueueRatio(queued, totalAssets)
    C->>SAF: checkAccountingLiveness()
    SAF-->>C: if breached => CircuitBreakerTriggered + Paused

    Note over G,SAF: Guardian can pause/unpause
    G->>SAF: pause()
    G->>SAF: unpause()

    Note over GOV,SAF: Admin updates safety parameters
    GOV->>SAF: setDepositCap(cap)
    GOV->>SAF: setWithdrawalMinimum(minShares)
    GOV->>SAF: setMinRateDropBps(minBps)
    GOV->>SAF: setMaxQueueRatioBps(maxBps)
    GOV->>SAF: setMaxAccountingDelay(maxDelay)
```

## Upgrades

```mermaid
sequenceDiagram
    participant GOV as Governance (admin)
    participant C as OllaCore (proxy)
    participant SM as StakingManager (proxy)
    participant WQ as WithdrawalQueue (proxy)
    participant RV as RewardsVault (proxy)
    participant SPR as StakingProviderRegistry (proxy)

    Note over GOV,C: Governance controls DEFAULT_ADMIN_ROLE
    GOV->>C: upgradeTo(newImplementation)
    C->>C: _authorizeUpgrade (governance check)

    GOV->>SM: upgradeTo(newImplementation)
    SM->>SM: _authorizeUpgrade (governance check)

    GOV->>WQ: upgradeTo(newImplementation)
    WQ->>WQ: _authorizeUpgrade (admin role)

    GOV->>RV: upgradeTo(newImplementation)
    RV->>RV: _authorizeUpgrade (admin role)

    GOV->>SPR: upgradeTo(newImplementation)
    SPR->>SPR: _authorizeUpgrade (governance check)
```
