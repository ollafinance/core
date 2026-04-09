# Olla Core

[![Unit tests](https://github.com/ollafinance/olla-core/actions/workflows/foundry-unit-tests.yml/badge.svg)](https://github.com/ollafinance/olla-core/actions/workflows/foundry-unit-tests.yml)
[![Invariant tests](https://github.com/ollafinance/olla-core/actions/workflows/foundry-invariant-tests.yml/badge.svg)](https://github.com/ollafinance/olla-core/actions/workflows/foundry-invariant-tests.yml)
[![Slither](https://github.com/ollafinance/olla-core/actions/workflows/slither.yml/badge.svg)](https://github.com/ollafinance/olla-core/actions/workflows/slither.yml)
[![Solidity lint](https://github.com/ollafinance/olla-core/actions/workflows/solidity-lint.yml/badge.svg)](https://github.com/ollafinance/olla-core/actions/workflows/solidity-lint.yml)
[![Storage layout](https://github.com/ollafinance/olla-core/actions/workflows/storage-layout-check.yml/badge.svg)](https://github.com/ollafinance/olla-core/actions/workflows/storage-layout-check.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

**Olla** is a liquid staking protocol for Aztec. This repository contains the Ethereum smart contract layer: an ERC-7540/ERC-4626 vault that holds user assets and mints stAztec, an accounting and rebalancing engine, staking and staking-provider registry modules, a safety module, LayerZero V2 bridging, and a timelocked governance contract.

**Status**: currently deployed on Sepolia; mainnet launch pending.

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
- `docs/` Protocol overview, architecture, security, and deployment documentation.
- `mock-loop/` TypeScript harness for driving the protocol against a local chain (see [`mock-loop/README.md`](mock-loop/README.md)).

## Learn more

- [Documentation site](https://docs.olla.finance)
- [Protocol overview](docs/architecture/overview.md)
- [User actions](docs/architecture/user-actions.md) · [Operator actions](docs/architecture/operator-actions.md) · [Governance actions](docs/architecture/governance-actions.md)
- [Trust assumptions](docs/security/trust-assumptions.md)
- [Security policy](SECURITY.md)
- [Audit reports](audits/)

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for development setup, build and test commands, linting, static analysis, and the issue/PR process. All contributors are expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
