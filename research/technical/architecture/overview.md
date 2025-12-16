# Olla V1 Overview

**Protocol Name**: Olla Liquid Staking Protocol  
**Primary Purpose**: Stake to a trusted Aztec L2 validator while staying liquid via a non-rebasable token (stAztec)  
**Target Network**: Aztec L2 (privacy-focused zkRollup)  
**Version**: 1.0 (MVP)

**V1 Focus**: Ship a secure, functional liquid staking protocol with minimal complexity. Security, auditability, and core functionality come first; multi-validator routing and decentralization are deferred.

```
┌─────────────────────────────────────────────────────┐
│                    Olla V1 MVP                      │
│                                                     │
└─────────────────────────────────────────────────────┘

Core Contracts (7):
├─ OllaCore.sol                    Main vault and coordination hub
├─ StAztec.sol                     Non-rebasable liquid staking token
├─ RewardsVault.sol                Validator reward accumulation
├─ StakingManager.sol              Delegation layer and key management
├─ WithdrawalQueue.sol             Simple FIFO withdrawal processing
├─ SafetyModule.sol                Deposit caps and circuit breakers
└─ GuardianMultisig.sol            Emergency controls

Support / External Dependencies:
└─ Single Aztec validator (trusted operator)
```

## How to navigate

- Architecture flows: `flows.md`
- Invariants and accounting: `invariants.md`
- Component specs: `components/*.md`
- Interfaces and roles: `interfaces-and-roles.md`
- Operations and safety: `operations-and-controls.md`
- Launch constraints: `launch-constraints.md`
- Development milestones: `milestones.md`
- V2 roadmap: `v2-roadmap.md`

