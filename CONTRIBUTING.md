# Contributing to Olla Core

Thanks for your interest in contributing. The most valuable contributions start with a clear issue
and end with a focused PR that is easy to review.

## Development

### Tooling

- Solidity + Foundry for development and testing (`forge fmt` is pinned to v1.4.1).
- Solhint for Solidity linting (includes a custom rule plugin under `solhint-rules/`).
- Slither + Slytherin for static analysis.
- Yarn for JavaScript/TypeScript tooling (mock loop, lint, storage-layout checks).

### Quickstart

From the repo root:

```bash
cd contracts
forge soldeer install
forge build
forge test
```

### Local development

Start a local Anvil chain and deploy the protocol:

```bash
# Terminal 1: start chain
yarn dev:chain

# Terminal 2: deploy contracts
yarn deploy:local
```

Run only the invariant suite:

```bash
cd contracts
forge test --match-path "test/**/*.invariant.t.sol"
```

For automated protocol testing with the TypeScript mock loop, see [`mock-loop/README.md`](mock-loop/README.md).

### Test layout and naming

- Module-local tests live under the matching module directory in `contracts/test/`.
- Cross-module tests live in `contracts/test/integration/` and use `*.integration.t.sol`.
- Invariant tests use `*.invariant.t.sol`.
- E2E tests live in `contracts/test/e2e/` and use `*.e2e.t.sol`.

### Linting

```bash
yarn install
yarn lint
```

`yarn install` also wires up Husky pre-commit hooks (via `postinstall`) that enforce linting on every commit. The custom Solhint rules live in `solhint-rules/` and are built automatically by the lint script — see [`solhint-rules/README.md`](solhint-rules/README.md) for details.

### Static analysis

Slither is pinned in CI to `0.11.4` (see `.github/workflows/slither.yml`). Slitherin is pinned to `0.7.2` and patched for Slither 0.11.4 compatibility.

To run Slither via Docker (uses `contracts/Dockerfile.slither`):

```bash
yarn slither:docker
```

### Storage layout checks

All upgradeable contracts use a standardized `uint256[50]` storage gap. CI validates that storage layouts match committed fixtures on every PR.

Check all layouts against their fixtures:

```bash
yarn check:storage
```

If the change is intentional (e.g., added a new state variable and shrunk the gap), regenerate all fixtures:

```bash
yarn check:storage:update
```

Commit the updated fixtures alongside the contract change.

## Issues

Before opening a new issue, search existing issues to avoid duplicates.

A good issue includes:

- A concise title that summarizes the problem or feature.
- Context and motivation: why this matters for the protocol.
- A clear description of expected behavior vs current behavior (for bugs).
- Minimal, reproducible steps (for bugs) and any relevant logs or traces.
- Scope boundaries: what is in-scope and out-of-scope.
- Acceptance criteria: what "done" looks like.

If you are proposing a change, include:

- Proposed approach and alternatives considered.
- Impact on security, upgradeability, and on-chain interfaces.
- Any open questions or risks.

## Pull requests

Please open a PR only after the related issue is accepted or discussed.

Guidelines for a strong PR:

- Keep the change set small and focused.
- Reference the issue with "Closes #123" or "Relates to #123".
- Update or add tests when behavior changes.
- Update docs when public interfaces or assumptions change.
- Avoid new dependencies without prior discussion.

## Review process

- A maintainer will triage issues and PRs.
- PRs may require changes; please keep feedback cycles tight.
- Security-sensitive changes may undergo additional review.

## Security

If you discover a security issue, **do not open a public issue or pull request**. Follow the responsible disclosure process in [`SECURITY.md`](SECURITY.md).
