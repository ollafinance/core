# Phase 1: Upgradeability (UUPS)

## Goal

Convert `contracts/src/core/StakingManager.sol` to a UUPS upgradeable contract (ERC1967 proxy), following patterns used by:

- `contracts/src/core/OllaCore.sol`
- `contracts/src/core/WithdrawalQueue.sol`

## Contract Changes

- Replace constructor-based initialization with:
  - `constructor() { _disableInitializers(); }`
  - `initialize(...) external initializer`
- Replace immutables with storage variables:
  - `IERC20 public STAKING_ASSET;`
  - `IAztecRollupRegistry public ROLLUP_REGISTRY;`
  - `IRewardsVault public REWARDS_VAULT;`
  - `address public CORE;`
- Add upgrade authorization:
  - `function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE)`
  - Additional governance check like `OllaCore` (use the same address as DEFAULT_ADMIN by default).
- Add a storage gap.

## Test Changes

- Update `contracts/test/core/StakingManager.t.sol` to deploy behind `ERC1967Proxy` and call `initialize`.
- Update `contracts/test/core/StakingManager.invariant.sol` similarly.

## Verification

Run:

```bash
forge test --match-contract StakingManager -vvv
```
