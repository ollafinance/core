# Olla Core

Olla Core is the Ethereum smart contract layer for the Olla liquid staking protocol on Aztec.
This repository pairs a research vault with a Foundry-based contract workspace, and is structured
to grow into an open-source, auditable codebase.

## Repository layout

- `contracts/` Foundry project for the core contracts.
- `contracts/src/core/` Protocol core contracts.
- `contracts/src/modules/` Reusable modules (pause/roles/etc).
- `contracts/src/interfaces/` External-facing interfaces.
- `contracts/src/libraries/` Shared libraries.
- `contracts/src/mocks/` Test/mocked contracts and fixtures.
- `contracts/script/` Foundry scripts.
- `contracts/test/` Component-based Foundry tests (e.g., `core/`, `modules/`).
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

Invariant-only suite:

```bash
cd contracts
forge test --match-path "test/**/*.invariant.sol"
```

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

```bash
yarn slither
```

This runs Slither via Docker, cleaning build artifacts before and after to avoid permission issues.

For Slytherin, install the plugin and run:

```bash
cd contracts
slytherin .
```

## Contributing

See `CONTRIBUTING.md`.

## License

Apache-2.0. See `LICENSE`.
