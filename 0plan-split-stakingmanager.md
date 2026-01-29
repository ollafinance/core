# Plan: Split `StakingManager.sol` into `StakingManager` + `StakingProviderRegistry`

Goal: `StakingManager` only coordinates Aztec rollup stake/unstake flows (core-gated), while provider configuration + attester key queue management lives in a new `StakingProviderRegistry` (provider-admin role-gated, plus a small core-only API).

## Current Situation

`contracts/src/staking/StakingManager.sol` currently does two things:

1. Coordinates deposits/withdrawals on `IAztecRollup` (stake/unstake/cleanup/claim/harvest/accounting reads).
2. Acts as a registry for a staking provider:
   - stores provider config (`ProviderConfig`)
   - stores a FIFO key queue (`QueueLib` over `IStakingManager.KeyStore`)
   - exposes provider-admin functions (`addKeysToProvider`, `dripQueue`, `setProviderRewardsRecipient`) and views (`getQueueLength`, `getProviderConfig`).

We want to split (2) into a new contract and also split interfaces so provider-admin functions are no longer exposed via `StakingManager`.

Non-goal: migrations / upgrade-safe state transfers (not live yet).

## Desired End State

### `StakingManager`

- Responsibilities:
  - Aztec rollup stake orchestration: `stake`, `unstake`, `cleanActivatedAttesters`, `getUnstakedFunds`, `harvestRewards`.
  - Accounting reads used by core: `getClaimableRewards`, `getSlashingDelta`, `totalStaked`, `getStakingState`, plus activated/pending views.
- Access:
  - All state-changing rollup coordination remains `onlyCore` (where `core` is `OllaCore`).
- Provider registry:
  - Holds a reference to `StakingProviderRegistry`.
  - During `stake()`, obtains attester keystores from the registry.
  - Exposes provider config as a view wrapper (to avoid changing `OllaCore` call sites): `getProviderConfig()` returns `registry.getStakingProviderConfig()`.
- Provider-admin functions:
  - Not present / not exposed.

### `StakingProviderRegistry`

- Responsibilities:

  - Stores provider config (`ProviderConfig`) and key queue (`QueueLib`).
  - Provider-admin role can:
    - `setProviderRewardsRecipient`
    - manage the queue (`addKeysToProvider`, `dripQueue`)
  - Core-only API (called by `StakingManager`):
    - `getAttesterKeystore()` (wrapper-ish around `QueueLib.dequeue()`)
    - `getStakingProviderConfig()` (view)
    - `getQueueLength()` (view)

- Base contracts (match repo patterns):
  - `Initializable`, `AccessControlUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuard`

## Key Design Choice

In `StakingProviderRegistry`, the privileged caller check should be `msg.sender == stakingManager` (and not mention “core” at all).

Rationale:

- `stake()` runs inside `StakingManager`; it must dequeue keys as part of staking.
- Gating consumption to the `stakingManager` address keeps the queue consumption surface area minimal.

Implication:

- `StakingManager` becomes the only contract that can consume keystores; `OllaCore` continues to call `StakingManager` only.

## Interface Split

We will split `IStakingManager` into:

1. `contracts/src/staking/interfaces/IStakingManager.sol`

   - Keep: rollup coordination + accounting reads + views needed by core.
   - Keep: `ProviderConfig` struct and `getProviderConfig()` view (used by `OllaCore` to mint provider shares).
   - Remove from this interface:
     - `addKeysToProvider`, `dripQueue`, `setProviderRewardsRecipient`, `getQueueLength`

2. `contracts/src/staking/interfaces/IStakingProviderRegistry.sol`
   - Own: provider-admin API + core-only dequeue/config.
   - Reuse types from `IStakingManager`:
     - `IStakingManager.KeyStore`
     - `IStakingManager.ProviderConfig`

Note: `QueueLib` currently imports `IStakingManager` to type its storage (`IStakingManager.KeyStore`). This is fine; the registry will also import `IStakingManager` for the same reason.

## Contract Changes (High-Level)

### 1) Add `StakingProviderRegistry`

Create `contracts/src/staking/StakingProviderRegistry.sol`:

- Base: `Initializable`, `AccessControlUpgradeable`, `UUPSUpgradeable`, `ReentrancyGuard`.
- Role constant:
  - `STAKING_PROVIDER_ADMIN_ROLE = RolesLib.STAKING_PROVIDER_ADMIN_ROLE`.
- State:
  - `address public stakingManager;` (set to `address(stakingManager)`)
  - `ProviderConfig private _provider;`
  - `Queue private _providerQueue;` (via `QueueLib`)
  - `uint256[__] __gap;`
- Modifiers:
  - `onlyStakingManager` for `msg.sender == stakingManager`.
- Functions:
  - `initialize(stakingManager_, providerAdmin_, providerRewardsRecipient_, defaultAdmin_)`:
    - validates non-zero
    - sets `stakingManager`, `_provider`, initializes queue
    - grants `DEFAULT_ADMIN_ROLE` to `defaultAdmin_`
    - grants `STAKING_PROVIDER_ADMIN_ROLE` to `providerAdmin_`
    - emits `ProviderSet(providerAdmin_, providerRewardsRecipient_)`
  - Provider-admin:
    - `addKeysToProvider(KeyStore[] calldata)` -> enqueue; emit `KeysAddedToProvider`
    - `dripQueue(uint256)` -> dequeue N; emit `QueueDripped` per key
    - `setProviderRewardsRecipient(address)` -> update; emit `ProviderSet`
- Core-only:
  - `getAttesterKeystore()` -> `dequeue()` and return
  - `getStakingProviderConfig()` -> return `_provider`
  - Views:
    - `getQueueLength()` -> queue length

Events:

- Reuse `IStakingManager` events for provider config + queue events to avoid duplicating semantics.

### 2) Refactor `StakingManager` to use the registry

Update `contracts/src/staking/StakingManager.sol`:

- Remove provider role constant + role usage from `StakingManager`.
- Remove provider queue + provider config usage from staking flow.
- Add a registry reference:

  - `IStakingProviderRegistry public stakingProviderRegistry;`
  - Since we are not live and not doing upgrades/migration considerations, we can also delete old `_provider` / `_providerQueue` state if desired; otherwise keep but unused.

- In `initialize(...)`:

  - Deploy `StakingProviderRegistry` and initialize it.
  - Set registry `stakingManager` to `address(this)` (so only `StakingManager` can dequeue keys).

- In `_stake(...)` / `_stakeAttesters(...)`:

  - Replace `_providerQueue.length()` with `stakingProviderRegistry.getQueueLength()`
  - Replace `_providerQueue.dequeue()` with `stakingProviderRegistry.getAttesterKeystore()`

- Keep `getProviderConfig()` (for `OllaCore`) and delegate:
  - `return stakingProviderRegistry.getStakingProviderConfig();`

### 3) Update core usage (`OllaCore`)

No change expected to `contracts/src/core/OllaCore.sol` because it only requires:

- `modules.stakingManager.getProviderConfig().rewardsRecipient` (still available on `IStakingManager`).

## Test Plan

1. Move provider-admin tests out of `contracts/test/staking/StakingManager.t.sol` into a new file:

   - `contracts/test/staking/StakingProviderRegistry.t.sol`
   - Cover:
     - role gating for provider admin
     - queue enqueue/dequeue + events
     - set rewards recipient + event

2. Update staking flow tests in `contracts/test/staking/StakingManager.t.sol`:

   - Replace `stakingManager.addKeysToProvider(...)` with calls to the registry instance.
   - Ensure `stake()` still works by consuming keys from the registry.

3. Update mocks:
   - `contracts/src/staking/mocks/MockStakingManager.sol`:
     - remove provider-admin funcs to match new `IStakingManager`.
   - Any accounting mocks (`contracts/test/mocks/MockAccountingStakingManager.sol`) should still implement `getProviderConfig()`.

## Implementation Order

1. Add `IStakingProviderRegistry`.
2. Implement `StakingProviderRegistry`.
3. Split `IStakingManager` (remove provider-admin funcs; keep provider config view).
4. Update `StakingManager` to consume the registry.
5. Update tests and mocks to match interface split.
6. Run forge tests.

## Checklist

- `StakingManager` has no provider-admin external functions.
- Only `StakingManager` can consume keystores (registry `onlyCore`).
- Provider admin manages queue + rewardsRecipient via `StakingProviderRegistry` only.
- `OllaCore` continues reading provider recipient via `IStakingManager.getProviderConfig()`.
