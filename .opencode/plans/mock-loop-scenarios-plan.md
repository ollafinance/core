# Mock-Loop Scenarios Expansion Plan

This plan covers the addition of new scenarios to the mock-loop testing harness to improve protocol coverage, multi-user testing, edge case validation, and runtime invariant checking.

## Overview

The current mock-loop has 8 scenarios covering the happy-path protocol lifecycle: deposit, stake, rebalance, accounting, rewards, withdraw, claim, and governance transfer. This expansion adds **14 new scenarios** across 4 phases to cover slashing, multi-user interactions, error paths, and invariant validation.

## Phase Summary

| Phase | Scope | New Scenarios |
|-------|-------|---------------|
| [Phase 1](./mock-loop-scenarios-phase1-core-protocol.md) | Core protocol flows missing from mock-loop | slashing, external-exit, safety-module |
| [Phase 2](./mock-loop-scenarios-phase2-multi-user.md) | Multi-user & full lifecycle coverage | multi-user-deposit, partial-withdraw, deposit-after-withdraw |
| [Phase 3](./mock-loop-scenarios-phase3-edge-cases.md) | Edge cases & error path scenarios | negative-rewards-period, gas-threshold, governance-rejection, withdraw-before-finalization |
| [Phase 4](./mock-loop-scenarios-phase4-invariants.md) | Invariant checking & infrastructure | invariant-checker, accounting-timestamp, dynamic-finalization refactor, config profiles |

## Architecture Context

```
mock-loop/
├── index.ts                          # Main loop orchestrator
├── config.ts                         # Default scenario schedule
├── lib/
│   ├── types.ts                      # Type definitions (add new scenario types here)
│   ├── state.ts                      # Protocol state reader (extend for new state fields)
│   ├── client.ts                     # Viem clients & contract helpers
│   ├── logger.ts                     # Console + file logging
│   ├── output.ts                     # Run directory management
│   └── scenarios/
│       ├── provider-keys.ts          # Existing
│       ├── mock-rewards.ts           # Existing
│       ├── user-deposit.ts           # Existing
│       ├── rebalance.ts              # Existing
│       ├── accounting.ts             # Existing
│       ├── user-initiate-withdraw.ts # Existing
│       ├── user-claim.ts             # Existing
│       ├── governance-change.ts      # Existing
│       ├── slashing.ts               # Phase 1 - NEW
│       ├── external-exit.ts          # Phase 1 - NEW
│       ├── safety-module.ts          # Phase 1 - NEW
│       ├── multi-user-deposit.ts     # Phase 2 - NEW
│       ├── partial-withdraw.ts       # Phase 2 - NEW
│       ├── deposit-after-withdraw.ts # Phase 2 - NEW
│       ├── negative-rewards.ts       # Phase 3 - NEW
│       ├── gas-threshold.ts          # Phase 3 - NEW
│       ├── governance-rejection.ts   # Phase 3 - NEW
│       ├── withdraw-before-final.ts  # Phase 3 - NEW
│       ├── invariant-checker.ts      # Phase 4 - NEW
│       └── accounting-timestamp.ts   # Phase 4 - NEW
```

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `mock-loop/lib/types.ts` | Modify | Add 11 new scenario type interfaces + update `ScenarioConfig` union |
| `mock-loop/lib/state.ts` | Modify | Add safety module state, attester exit state, multi-user tracking |
| `mock-loop/lib/client.ts` | Modify | Add contract helpers for SafetyModule, rollup slashing functions |
| `mock-loop/index.ts` | Modify | Add routing for new scenario types in `executeScenario()` switch |
| `mock-loop/config.ts` | Modify | Add default schedules for new scenarios (disabled by default) |
| `mock-loop/lib/scenarios/*.ts` | Create | 11 new scenario files (see phases) |
| `mock-loop/configs/stress-test.ts` | Create | Multi-user stress test config profile |
| `mock-loop/configs/adversarial.ts` | Create | Adversarial edge-case config profile |

## Dependencies Between Phases

```
Phase 1 (core protocol) ──► Phase 3 (edge cases depend on slashing scenario)
                          └► Phase 4 (invariant checker validates slashing state)
Phase 2 (multi-user)     ──► Phase 4 (invariant checker validates multi-user balances)
```

Phase 1 and Phase 2 can be implemented in parallel. Phase 3 depends on Phase 1 (slashing). Phase 4 depends on both Phase 1 and Phase 2.

## Verification

```bash
# Run expanded mock-loop with default config (new scenarios disabled)
npx tsx mock-loop/index.ts --once

# Run with stress test profile
npx tsx mock-loop/index.ts --config mock-loop/configs/stress-test.ts --once

# Run with adversarial profile
npx tsx mock-loop/index.ts --config mock-loop/configs/adversarial.ts --once

# Run until first error to validate edge cases
npx tsx mock-loop/index.ts --config mock-loop/configs/adversarial.ts --until-error
```
