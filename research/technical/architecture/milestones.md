# Development Milestones

## Milestone 1: Research and Architecture
- **Objective:** Define Olla’s core architecture and establish the foundation for V1 implementation.
- **Deliverables:** System architecture doc; interface definitions; security model.
- **Success:** Interface layout approved; invariants documented; security review complete.

## Milestone 2: Token System (StAztec)
- **Objective:** Implement the non-rebasable liquid staking token.
- **Deliverables:** StAztec implementation; ERC20 and permit tests; access control tests.
- **Success:** ERC20 and permit compliant; only OllaCore can mint or burn; high coverage.

## Milestone 3: Core Protocol Contract (OllaCore)
- **Objective:** Implement the main vault and coordination hub.
- **Deliverables:** OllaCore implementation; deposit/withdraw/accounting tests; integrations to StakingManager, WithdrawalQueue, RewardsVault, SafetyModule, AztecRollup.
- **Success:** End-to-end deposit flows; exchange rate matches spec; invariants hold; high coverage.

## Milestone 4: Staking Delegation (StakingManager)
- **Objective:** Implement the staking delegator managing the single staking provider, validator keys, and staking flow.
- **Deliverables:** StakingManager implementation; provider admin vs core roles; staking/unstaking/key events; queue tests; integration tests with mocks.
- **Success:** Roles enforced; key queue behaves correctly; stake/unstake/harvest flows validated; `totalStaked()` accurate.

## Milestone 5: Revenue and Fee Management
- **Objective:** Rewards accumulation and fee distribution inside OllaCore.
- **Deliverables:** RewardsVault implementation; reward inflow handling; fee calculation and share minting in `updateAccounting()`; access control.
- **Success:** Rewards accumulate correctly; accounting includes rewards; fee shares minted to treasury and provider; high coverage on reward/fee paths.

## Milestone 6: Withdrawal System
- **Objective:** FIFO withdrawal processing that locks value at request time and finalizes when liquidity is available.
- **Deliverables:** WithdrawalQueue implementation and queue mechanics; integration from `OllaCore.requestWithdrawal` and `rebalance` finalization; claim flow; unit and integration tests.
- **Success:** Strict FIFO; locked `assetsExpected` preserved; no double claims; edge cases (partial liquidity, paused, under-collateralization) covered.

## Milestone 7: Cement Accounting and Integrations
- **Objective:** Deterministic accounting without external oracles; SafetyModule hooks for circuit breakers.
- **Deliverables:** OllaCore `updateAccounting` uses on-chain module data; floor-based rounding; fee calculation formula; SafetyModule rate-drop and liveness checks.
- **Success:** Reliable `totalAssets`; out-of-range validator data triggers protections; deterministic on-chain accounting.

## Milestone 8: Rebalance Logic
- **Objective:** Full `rebalance()` path to maintain buffers, finalize withdrawals, and stake surplus.
- **Deliverables:** Harvest, pull unstaked, process withdrawals, stake excess; single `Rebalanced(...)` summary event; liquidity accounting updates; safety checks.
- **Success:** Withdrawals prioritized before staking; surplus staked; idempotent repeated calls; queue drains with liquidity; fuzzed under heavy flows.

## Milestone 9: Safety Module
- **Objective:** Deposit caps and circuit breakers for abnormal conditions.
- **Deliverables:** SafetyModule implementation; integration checks in deposit/updateAccounting/withdrawal handling; admin wiring tests.
- **Success:** Deposits blocked after cap; rate drops or queue pressure pause the system; guardian can adjust or unpause safely.

## Milestone 10: Guardian System
- **Objective:** GuardianMultisig wired with correct powers in V1.
- **Deliverables:** Role assignments; guardian action surface (pause/unpause, cap and breaker adjustments, resets); runbooks; tests.
- **Success:** Guardian controls verified; non-guardian blocked; paused behavior matches spec.

## Milestone 11: Integration Tests and Gas Optimization
- **Objective:** Integrate all modules and validate safety and correctness.
- **Deliverables:** End-to-end flows; invariants tests; fuzz tests; breaker tests; gas profiling on hot paths.
- **Success:** Invariants hold under fuzzing; breakers work; no obvious DoS; gas reviewed on deposit/requestWithdrawal/claim/rebalance/updateAccounting.

## Milestone 12: Full Audit
- **Objective:** Secure production readiness via independent audits.
- **Deliverables:** External audit reports; fixes; final sign-off.
- **Success:** All critical/high issues resolved; residual risks documented; ready for guarded mainnet launch with configured caps.

