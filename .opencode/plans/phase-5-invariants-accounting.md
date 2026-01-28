# Phase 5 — Update Invariants and Accounting

Scope
- Update `research/technical/architecture/invariants.md`.

Edits
- Align `totalAssets()` decomposition and the source of each term.
- Describe end-state accounting update flow:
  - Inputs read, safety checks, fee computation (treasury/provider), exchange rate publication.
- Add/adjust circuit-breaker invariants driven by SafetyModule (rate drop, queue ratio, accounting liveness).

Acceptance
- Invariants are stated in a way testable against the contracts.
- Diagrams match the end-state flow naming.
