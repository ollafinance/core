# Phase 2: Update Dev Agent and Create Test Agent

**Issue**: #107 - Improvement: Improve the AI workflow by splitting up and creating more dedicated AI agents for coding, writing tests and auditing/reviewing

## Scope

- Update `.opencode/agent/smart-contract-dev.md` to be coding-only
- Add new `.opencode/agent/smart-contract-test.md` focused on Foundry testing

## Prerequisites

- Phase 1 scope definitions agreed

## Implementation Steps

1. Edit `.opencode/agent/smart-contract-dev.md`:
   - Remove testing/audit/optimization language from description and examples.
   - Update behavior guidelines to emphasize implementation only.
   - Add explicit handoff triggers to `smart-contract-test` and `smart-contract-review`.
   - Keep tooling references consistent with current Foundry setup.
2. Create `.opencode/agent/smart-contract-test.md`:
   - Description: testing-only (unit/fuzz/invariant/integration) using Foundry.
   - System context: Foundry test focus; project root `./contracts`.
   - Behavior guidelines: no contract implementation edits except minimal test fixtures/mocks.
   - Include examples of when to use the testing agent.

### Handoff Trigger Example

```text
If the user asks for tests, fuzzing, invariants, or coverage, hand off to smart-contract-test.
If the user asks for security review, audit, or optimization notes, hand off to smart-contract-review.
```

## Test Cases from Issue

- N/A (documentation change)

## Acceptance Criteria

- Smart contract dev agent is focused on coding actual smart contracts
- Smart contract testing agent is focused on writing tests for contracts

## Verification

- Confirm dev agent description contains no testing/audit/optimization responsibilities
- Confirm test agent description explicitly scopes to Foundry tests only
