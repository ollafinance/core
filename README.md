# Olla Core

Olla is a liquid staking protocol for Aztec. This repository contains the Ethereum smart contract
layer: an ERC-7540/ERC-4626 vault that holds user assets and mints stAztec, an accounting and
rebalancing engine, staking and staking-provider registry modules, a safety module, LayerZero V2
bridging, and a timelocked governance contract.

**Status**: currently deployed on Sepolia; mainnet launch pending.

**[Documentation](https://docs.olla.finance)** · [Trust assumptions](docs/security/trust-assumptions.md)

## Repository layout

`contracts/` is a Foundry project holding the core contracts. Each module directory under `contracts/src/` additionally contains `interfaces/`, `libraries/`, and `mocks/` subdirectories where applicable.

- `contracts/src/core/` Protocol core contracts (`OllaCore`, `RewardsAccumulator`).
- `contracts/src/vault/` ERC-7540 vault contracts (`OllaVault`, `StAztec`, `WithdrawalQueue`).
- `contracts/src/staking/` Staking module contracts (`StakingManager`, `StakingProviderRegistry`).
- `contracts/src/safetymodule/` Safety module contracts (`SafetyModule`, `ISafetyModule`).
- `contracts/src/governance/` Governance contract and interface (`OllaGovernance` with embedded timelock).
- `contracts/src/bridge/` LayerZero V2 OFT adapter (`StAztecOFTAdapter`). The paired OFT (`StAztec`) lives under `contracts/src/vault/`.
- `contracts/src/shared/` Shared libraries used across modules (e.g., `RolesLib`).
- `contracts/test/` Component-based Foundry tests mirroring the `src/` layout (`core/`, `vault/`, `bridge/`, `governance/`, `safetymodule/`, `staking/`, `integration/`, `e2e/`, `mocks/`).
- `docs/` Protocol overview, architecture, and deployment documentation.
- `mock-loop/` TypeScript harness for driving the protocol against a local chain (see [`mock-loop/README.md`](mock-loop/README.md)).
## Tooling

- Solidity + Foundry for development and testing
  - `forge fmt` is done with v1.4.1
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

For strict-chain activation after deployment (Sepolia/Mainnet), see `contracts/script/docs/live.md` and use `contracts/script/ops/PrintNextActivationPayload.s.sol` to generate the next Safe payload from live on-chain state.

For automated protocol testing with the TypeScript mock loop, see [`mock-loop/README.md`](mock-loop/README.md).

Invariant-only suite:

```bash
cd contracts
forge test --match-path "test/**/*.invariant.t.sol"
```

## Test layout and naming

- Module-local tests live under the matching module directory in `contracts/test/`.
- Cross-module tests live in `contracts/test/integration/` and use `*.integration.t.sol`.
- Invariant tests use `*.invariant.t.sol`.
- E2E tests live in `contracts/test/e2e/` and use `*.e2e.t.sol`.

## Linting

```bash
yarn install
yarn lint
```

The custom Solhint rules live in `solhint-rules/` and are built automatically by the lint script. For more details, see `solhint-rules/README.md`.

`yarn install` also wires up Husky pre-commit hooks (via `postinstall`) that enforce linting on every commit.

## Static analysis

- Slither is pinned in CI to `0.11.4` (see `.github/workflows/slither.yml`).
- Slitherin is pinned in CI to `0.7.2` and patched for Slither 0.11.4 compatibility.

To run via Docker (uses `contracts/Dockerfile.slither`):

```bash
yarn slither:docker
```

## Storage layout checks

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

## Contributing

See `CONTRIBUTING.md`.

## License

Apache-2.0. See `LICENSE`.
