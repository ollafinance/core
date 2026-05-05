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
    Note over GOV,C: setTreasuryFeeSplitBP, setRebalanceGasThreshold,
    Note over GOV,C: setRebalanceCooldown, setSafetyModule,
    Note over GOV,C: reconcileBufferedAssets, recoverStAztec
    Note over GOV,C: (setVault is invoked through the timelock against OllaCore directly)
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

Governance transfer is initiated via the timelock but accepted directly by the new governance address. On acceptance, `OllaGovernance` atomically transfers timelock roles (proposer/executor/canceller) and `DEFAULT_ADMIN_ROLE` from the old governance admin to the new one.

The `OllaGovernance` *contract address itself* is the `DEFAULT_ADMIN_ROLE` holder on every satellite (`OllaCore`, `OllaVault`, `SafetyModule`, `RewardsAccumulator`, `StakingManager`, `StakingProviderRegistry`). Because the contract address does not change when the governance admin wallet is rotated, no per-satellite role propagation is needed; the new governance admin steers those roles by scheduling timelock actions on `OllaGovernance`, which holds them on every satellite.

```mermaid
sequenceDiagram
    participant GOV as Current Governance Admin
    participant OG as OllaGovernance (timelock)
    participant NEW as New Governance Admin

    GOV->>OG: schedule(proposeGovernance(newGov))
    Note right of OG: Wait for minDelay
    GOV->>OG: execute(proposeGovernance(newGov))
    OG->>OG: proposeGovernance(newGov) [onlySelf]
    OG-->>GOV: GovernanceTransferProposed(oldGov, newGov)

    NEW->>OG: acceptGovernance()
    Note right of OG: Direct call, not timelocked
    OG->>OG: grant PROPOSER/EXECUTOR/CANCELLER/DEFAULT_ADMIN_ROLE to newGov
    OG->>OG: revoke PROPOSER/EXECUTOR/CANCELLER/DEFAULT_ADMIN_ROLE from oldGov
    OG->>OG: governanceAdmin = newGov
    OG-->>NEW: GovernanceTransferAccepted(oldGov, newGov)
    Note right of OG: Satellites are unaffected; OllaGovernance itself remains their admin

    opt cancel before accept
        GOV->>OG: schedule(cancelGovernanceProposal())
        Note right of OG: Wait for minDelay
        GOV->>OG: execute(cancelGovernanceProposal())
        OG-->>GOV: GovernanceTransferCancelled(pendingGovernance)
    end
```

## Treasury management

The treasury address is managed by `OllaGovernance` via the timelock. The treasury receives the treasury share of protocol fees minted on each accounting update.

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

The safety module circuit breaker is triggered automatically by OllaCore during operations. The configured guardian wallet can pause/unpause the SafetyModule directly. This path is not timelocked.

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

## Emergency pause / unpause

The governance admin can pause or unpause both `OllaCore` and `OllaVault` in a single call. These functions are **not timelocked** -- they are callable directly by the governance admin for rapid incident response. This works because `OllaGovernance` holds `GUARDIAN_ROLE` on `OllaCore` and `OllaVault` in the default deployment.

```mermaid
sequenceDiagram
    participant GOV as Governance Admin
    participant OG as OllaGovernance
    participant C as OllaCore
    participant V as OllaVault

    Note over GOV,V: Emergency pause
    GOV->>OG: emergencyPauseAll()
    OG->>C: pause()
    OG->>V: pause()
    OG-->>GOV: EmergencyPauseAll()

    Note over GOV,V: Emergency unpause
    GOV->>OG: emergencyUnpauseAll()
    OG->>C: unpause()
    OG->>V: unpause()
    OG-->>GOV: EmergencyUnpauseAll()
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

    Note over GOV,SAT: Upgrade satellite (OllaVault, RewardsAccumulator, StakingManager, StakingProviderRegistry)
    Note over GOV,SAT: SafetyModule is non-UUPS; replace via OllaCore.setSafetyModule instead
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
