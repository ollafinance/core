# Phase 3: Create Review Agent and Run Consistency Pass

**Issue**: #107 - Improvement: Improve the AI workflow by splitting up and creating more dedicated AI agents for coding, writing tests and auditing/reviewing

## Scope

- Add `.opencode/agent/smart-contract-review.md` for review/audit/optimization notes
- Run a consistency pass across agent names, tone, and tooling references
- Ensure acceptance criteria mapping is explicit

## Prerequisites

- Phase 2 changes in place

## Implementation Steps

1. Create `.opencode/agent/smart-contract-review.md`:
   - Description: review and audit only; no code changes except small snippets for illustration.
   - Require a structured report output (Summary, Findings, Risks, Recommendations, Optimization Notes, Test Gaps).
   - Emphasize vulnerability identification and improvement guidance.
2. Align naming, tone, and tooling references across all three agent docs:
   - Ensure consistent use of Foundry terms and repo paths.
   - Keep example prompts aligned with the new scopes.
3. Add an explicit acceptance criteria mapping section inside each agent doc:
   - `smart-contract-dev` maps to “coding actual smart contracts”.
   - `smart-contract-test` maps to “writing tests for contracts”.
   - `smart-contract-review` maps to “reviewing implementation, finding potential improvements and vulnerabilities”.

### Structured Report Template

```text
Summary:
Findings:
- [severity] [title] — [description]
Risks:
Recommendations:
Optimization Notes:
Test Gaps:
```

## Test Cases from Issue

- N/A (documentation change)

## Acceptance Criteria

- Auditing and reviewing agent is focused on reviewing implementation, finding potential improvements and vulnerabilities

## Verification

- Manual review of agent docs for consistent tone and explicit acceptance mapping
