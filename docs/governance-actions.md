# Governance actions

This document summarizes governance and admin flows in Olla Core. All governance actions flow through the `OllaGovernance` contract, which inherits `TimelockControllerUpgradeable`. Actions must be scheduled, wait for the timelock delay, and then executed.

## Configuration

All parameter changes are timelocked passthroughs: `OllaGovernance` receives the call via timelock execute and forwards it to `OllaCore`.

```mermaid
sequenceDiagram
    participant GOV as Governance Admin
    participant OG as OllaGovernance (timelock)
    participant C as OllaCore

    GOV->>OG: schedule(setProtocolFeeBP(newFee))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(setProtocolFeeBP(newFee))
    OG->>OG: setProtocolFeeBP(newFee) [onlySelf]
    OG->>C: setProtocolFeeBP(newFee)

    Note over GOV,C: Same pattern for all parameter setters:
    Note over GOV,C: setTreasuryFeeSplitBP, setInstantRedemptionFeeBP,
    Note over GOV,C: setTargetBufferedAssets, setRebalanceGasThreshold,
    Note over GOV,C: setRebalanceCooldown, reconcileBufferedAssets,
    Note over GOV,C: setSafetyModule, recoverStAztec
```

## Safety module configuration

Safety module parameters are also timelocked passthroughs. `OllaGovernance` reads the safety module address from `OllaCore` and calls it directly.

```mermaid
sequenceDiagram
    participant GOV as Governance Admin
    participant OG as OllaGovernance (timelock)
    participant C as OllaCore
    participant SAF as SafetyModule

    GOV->>OG: schedule(setDepositCap(cap))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(setDepositCap(cap))
    OG->>OG: setDepositCap(cap) [onlySelf]
    OG->>C: safetyModule()
    C-->>OG: safetyModule address
    OG->>SAF: setDepositCap(cap)

    Note over GOV,SAF: Same pattern for:
    Note over GOV,SAF: setWithdrawalMinimum, setMinRateDropBps,
    Note over GOV,SAF: setMaxQueueRatioBps, setMaxAccountingDelay
```

## Governance transfer (two-step)

Governance transfer is initiated via the timelock but accepted directly by the new governance address. On acceptance, `OllaGovernance` atomically transfers timelock roles (proposer/executor/canceller) and propagates `DEFAULT_ADMIN_ROLE` changes to all satellite contracts.

```mermaid
sequenceDiagram
    participant GOV as Current Governance Admin
    participant OG as OllaGovernance (timelock)
    participant NEW as New Governance
    participant WQ as WithdrawalQueue
    participant RV as RewardsVault
    participant SM as StakingManager
    participant SPR as StakingProviderRegistry

    GOV->>OG: schedule(proposeGovernance(newGov))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(proposeGovernance(newGov))
    OG->>OG: proposeGovernance(newGov) [onlySelf]
    OG-->>GOV: GovernanceTransferProposed(oldGov, newGov)

    NEW->>OG: acceptGovernance()
    Note right of OG: Direct call, not timelocked
    OG->>OG: grant PROPOSER/EXECUTOR/CANCELLER to newGov
    OG->>WQ: grantRole(DEFAULT_ADMIN_ROLE, newGov)
    OG->>RV: grantRole(DEFAULT_ADMIN_ROLE, newGov)
    OG->>SM: grantRole(DEFAULT_ADMIN_ROLE, newGov)
    OG->>SPR: grantRole(DEFAULT_ADMIN_ROLE, newGov)
    OG->>WQ: revokeRole(DEFAULT_ADMIN_ROLE, oldGov)
    OG->>RV: revokeRole(DEFAULT_ADMIN_ROLE, oldGov)
    OG->>SM: revokeRole(DEFAULT_ADMIN_ROLE, oldGov)
    OG->>SPR: revokeRole(DEFAULT_ADMIN_ROLE, oldGov)
    OG->>OG: revoke PROPOSER/EXECUTOR/CANCELLER from oldGov
    OG-->>NEW: GovernanceTransferAccepted(oldGov, newGov)

    opt cancel before accept
        GOV->>OG: schedule(cancelGovernanceProposal())
        Note right of OG: Wait for minDelay
        GOV->>OG: execute(cancelGovernanceProposal())
        OG-->>GOV: GovernanceTransferCancelled(pendingGovernance)
    end
```

## Treasury management

The treasury address (where instant redemption fees are sent) is managed by `OllaGovernance` via the timelock.

```mermaid
sequenceDiagram
    participant GOV as Governance Admin
    participant OG as OllaGovernance (timelock)

    GOV->>OG: schedule(setTreasury(newTreasury))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(setTreasury(newTreasury))
    OG->>OG: setTreasury(newTreasury) [onlySelf]
    OG-->>GOV: TreasuryUpdated(oldTreasury, newTreasury)
```

## Safety module circuit breaker

The safety module circuit breaker is triggered automatically by OllaCore during operations. The guardian can pause/unpause directly.

```mermaid
sequenceDiagram
    participant C as OllaCore
    participant SAF as SafetyModule
    participant G as Guardian

    Note over C,SAF: Core triggers breaker checks
    C->>SAF: checkRateDrop(oldRate, nextRate)
    C->>SAF: checkQueueRatio(queued, totalAssets)
    C->>SAF: checkAccountingLiveness()
    SAF-->>C: if breached => CircuitBreakerTriggered + Paused

    Note over G,SAF: Guardian can pause/unpause
    G->>SAF: pause()
    G->>SAF: unpause()
```

## Upgrades

All contract upgrades are timelocked. `OllaGovernance` has dedicated functions for upgrading OllaCore, satellite contracts, and itself.

```mermaid
sequenceDiagram
    participant GOV as Governance Admin
    participant OG as OllaGovernance (timelock)
    participant C as OllaCore (proxy)
    participant SAT as Satellite (proxy)

    Note over GOV,C: Upgrade OllaCore (owned by OllaGovernance)
    GOV->>OG: schedule(upgradeCore(newImpl))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(upgradeCore(newImpl))
    OG->>C: upgradeToAndCall(newImpl, "")

    Note over GOV,SAT: Upgrade satellite (WQ, RV, SM, SPR)
    GOV->>OG: schedule(upgradeSatellite(proxy, newImpl))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(upgradeSatellite(proxy, newImpl))
    OG->>SAT: upgradeToAndCall(newImpl, "")

    Note over GOV,OG: Self-upgrade OllaGovernance
    GOV->>OG: schedule(upgradeToAndCall(newImpl, ""))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(upgradeToAndCall(newImpl, ""))
    OG->>OG: _authorizeUpgrade(newImpl) [onlySelf]
```
