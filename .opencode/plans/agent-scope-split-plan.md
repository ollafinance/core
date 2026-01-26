# Smart Contract Agent Split Implementation Plan

This plan covers issue #107 for splitting the smart contract agent scope into dedicated dev, test, and review agents.

## Overview

The goal is to reduce agent scope overlap by:

- Narrowing `smart-contract-dev` to coding only
- Adding `smart-contract-test` for Foundry testing
- Adding `smart-contract-review` for review/audit/optimization notes

**Source of truth**: No architecture component spec exists for agent definitions; use existing `.opencode/agent/*.md` conventions and issue #107 requirements.

## Phase Summary

| Phase | Issue | Scope |
| ----- | ----- | ----- |
| [Phase 1](./agent-scope-split-phase1-audit.md) | #107 | Audit current agent + define scopes |
| [Phase 2](./agent-scope-split-phase2-dev-test.md) | #107 | Update dev agent + create test agent |
| [Phase 3](./agent-scope-split-phase3-review-consistency.md) | #107 | Create review agent + consistency pass |

## Architecture Context

OpenCode loads agent definitions from `.opencode/agent/*.md` with YAML frontmatter and embedded guidance sections. These files must stay consistent in tone, naming, and tooling references across the repo.

## Files to Create/Modify

| File | Description |
| ---- | ----------- |
| `.opencode/agent/smart-contract-dev.md` | Remove testing/audit language; add explicit handoff triggers |
| `.opencode/agent/smart-contract-test.md` | New testing-only agent definition |
| `.opencode/agent/smart-contract-review.md` | New review/audit/optimization agent definition |
| `.opencode/plans/agent-scope-split-*.md` | Plan documents for this issue |

## Verification

- Ensure all three agent descriptions explicitly map to issue #107 acceptance criteria
- Confirm handoff triggers point to the correct agent names
- Manual review for consistency with `.opencode/agent/olla-issue-planner.md` style
