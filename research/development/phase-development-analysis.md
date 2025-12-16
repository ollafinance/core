# Development Plan (V1)

This replaces the legacy phase-based roadmap. The authoritative build plan is the 12-milestone sequence in `research/technical/architecture/milestones.md`.

## Snapshot timeline (conceptual)

```mermaid
gantt
    title Olla V1 Delivery
    dateFormat  YYYY-MM-DD
    section Foundations
    Architecture & Interfaces      :active, m1, 2025-01-15, 21d
    Token (stAztec)                :m2, after m1, 21d
    Core Vault (OllaCore)          :m3, after m2, 28d
    StakingManager                 :m4, after m3, 21d

    section Flows & Safety
    Rewards & Fees                 :m5, after m4, 14d
    Withdrawal Queue               :m6, after m5, 21d
    Accounting & SafetyModule      :m7, after m6, 14d
    Rebalance Orchestration        :m8, after m7, 14d

    section Hardening
    Safety Module QA               :m9, after m8, 14d
    Guardian Wiring                :m10, after m9, 7d
    Integration + Gas              :m11, after m10, 21d
    External Audit                 :m12, after m11, 28d
```

## Execution guardrails
- **Single validator, single operator** in V1; defer multi-validator routing to V2.
- **No oracle contract**: rely on Aztec rollup state directly.
- **Protocol fee** minted as synthetic shares during accounting; fee split 50/50 treasury vs provider.
- **Safety first**: caps, circuit breakers, and guardian pause must be live before raising limits.

## Deliverable mapping
- Component specs: `research/technical/architecture/components/*.md`
- Interfaces/roles: `research/technical/architecture/interfaces-and-roles.md`
- Safety and ops runbooks: `research/technical/architecture/operations-and-controls.md`
- Launch constraints: `research/technical/architecture/launch-constraints.md`
