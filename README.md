# Olla Core

Olla Core is the Ethereum smart contract layer for the Olla liquid staking protocol on Aztec.
This repository pairs a research vault with a Foundry-based contract workspace, and is structured
to grow into an open-source, auditable codebase.

## Repository layout

- `contracts/` Foundry project for the core contracts.
- `docs/` Protocol overview and action references.
- `contracts/src/core/` Protocol core contracts.
- `contracts/src/core/interfaces/` Core module interfaces.
- `contracts/src/core/mocks/` Core module mocks and mock interfaces.
- `contracts/src/governance/` Governance contract and interface (OllaGovernance with embedded timelock).
- `contracts/src/safetymodule/` Safety module contracts and interface.
- `contracts/src/staking/` Staking module contracts.
- `contracts/src/staking/libraries/` Staking module libraries.
- `contracts/src/staking/interfaces/` Staking module interfaces.
- `contracts/src/staking/mocks/` Staking module mocks and mock interfaces.
- `contracts/script/` Foundry scripts.
- `contracts/test/` Component-based Foundry tests (e.g., `core/`, `governance/`, `safetymodule/`, `staking/`, `integration/`, `e2e/`).
- `research/` Protocol research and design notes (Obsidian vault).

Key research index:

- `research/technical/technical-architecture.md`

## Tooling

- Solidity + Foundry for development and testing
- Solhint for Solidity linting (includes a custom rule plugin)
- Slither + Slytherin for static analysis

## Quickstart

From the repo root:

```bash
cd contracts
forge soldeer install
forge build
forge test
```

## Local development

Start a local Anvil chain:

```bash
# Terminal 1: Start chain
yarn dev:chain

# Terminal 2: Deploy contracts
yarn deploy:local
```

### Governance

The `OllaGovernance` contract embeds a `TimelockController` and is deployed as part of the standard deploy flow (`yarn deploy:local`). It is automatically set as the owner of `OllaCore` and holds `DEFAULT_ADMIN_ROLE` on all satellite contracts. All governance actions (parameter changes, upgrades, governance transfers) must be scheduled, wait for the timelock delay, and then executed through `OllaGovernance`.

For automated protocol testing with the TypeScript mock loop, see [`mock-loop/README.md`](mock-loop/README.md).

Invariant-only suite:

```bash
cd contracts
forge test --match-path "test/**/*.invariant.t.sol"
```

## Test layout and naming

- Module-local tests live in `contracts/test/core/`, `contracts/test/safetymodule/`, and `contracts/test/staking/`.
- Cross-module tests live in `contracts/test/integration/` and use `*.integration.t.sol`.
- Invariant tests use `*.invariant.t.sol`.
- E2E tests (if added) live in `contracts/test/e2e/` and use `*.e2e.t.sol`.
- If E2E orchestration needs off-chain scripts, keep the harness in `contracts/test/e2e/` and place scripts in `contracts/script/e2e/`.

## Linting

```bash
yarn install
yarn lint
```

The custom Solhint rules live in `solhint-rules/` and are built automatically by the lint script. For more details, see `solhint-rules/README.md`.

To enforce linting on every commit, install dependencies to enable Husky hooks:

```bash
yarn install
```

If hooks still don't fire, run:

```bash
yarn husky install
```

## Static analysis

- Slither is pinned in CI to `0.11.4` (see `.github/workflows/slither.yml`).
- Slitherin is pinned in CI to `0.7.2` and patched for Slither 0.11.4 compatibility.

To run via Docker (uses `contracts/Dockerfile.slither`):

```bash
yarn slither:docker
```

## Storage layout checks

Run storage layout checks whenever upgradeable contracts change storage (new variables, reordered fields, or updated inheritance), and before preparing an upgrade or release.

Check the current layout against the fixture:

```bash
node contracts/script/check-storage-layout.ts --contract OllaCore --fixture contracts/upgrade/fixtures/OllaCore.storage.json
```

If the change is intentional, refresh the fixture from the Foundry output:

```bash
cd contracts
forge inspect OllaCore storageLayout > upgrade/fixtures/OllaCore.storage.json
```

## Contributing

See `CONTRIBUTING.md`.

## License

Apache-2.0. See `LICENSE`.
