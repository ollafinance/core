# Phase 1: Audit Current Agent and Define Scopes

**Issue**: #107 - Improvement: Improve the AI workflow by splitting up and creating more dedicated AI agents for coding, writing tests and auditing/reviewing

## Scope

- Audit `smart-contract-dev` to confirm it currently spans dev + test + audit + optimization
- Define the new scope boundaries for three agents

## Prerequisites

- Access to existing agent definitions in `.opencode/agent/`

## Implementation Steps

1. Review `.opencode/agent/smart-contract-dev.md` and extract all statements related to testing, auditing, and optimization.
2. Draft explicit scope definitions for three agents:

   ```text
   smart-contract-dev: coding only (no tests/audit/optimization)
   smart-contract-test: tests only (Foundry unit/fuzz/invariant/integration)
   smart-contract-review: review + audit + optimization notes
   ```

3. Add a short acceptance mapping list that ties each scope to the issue bullets so the changes can be validated during the consistency pass.

## Test Cases from Issue

- N/A (documentation change)

## Acceptance Criteria

- Smart contract dev agent is focused on coding actual smart contracts
- Smart contract testing agent is focused on writing tests for contracts
- Auditing and reviewing agent is focused on reviewing implementation, finding potential improvements and vulnerabilities

## Verification

- Manual scope check against the three definitions above
