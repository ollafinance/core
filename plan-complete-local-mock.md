## Goal

Provide a clean local workflow where a user opens three terminals and can:

- term-1: `yarn dev:chain` (anvil)
- term-2: `yarn deploy:local && yarn dev:local-start-mock-loop`
- term-3: run:
  - `yarn dev:local-god-mint-user 200000`
  - `yarn dev:local-user-deposit 200000`
  - later `yarn dev:local-operator-rebalance`
  - later `yarn dev:local-user-initiate-withdraw-all`
  - later `yarn dev:local-user-claim-withdrawals`

Constraints / intended behavior:

- New forge scripts live under `contracts/script/local/` (not `contracts/script/ops/`).
- Amount CLI args like `200000` are interpreted as whole tokens (18 decimals => `200000e18`).
- The mock-loop is a continuous process that increases rewards only when there is deposited/staked AZTEC in the rollup.
- Mint mints AZTEC to a default user address (anvil account-1), “god/admin/operator” can be deployer (anvil account-0).
- Deposit runs as the user and deposits AZTEC into OllaCore.
- Rebalance runs as operator (can be same as god/admin for now).
- Withdraw flow: user initiates withdraw-all (request redeem all shares), then later claims finalized withdrawals.

## Existing Building Blocks (already in repo)

- `yarn dev:chain`: runs `anvil`.
- `yarn deploy:local`: deploys local stack and writes `contracts/deployments/local.json`.
- Rollup reward primitives exist:
  - `contracts/script/rollup/SetRewardRate.s.sol`
  - `contracts/script/rollup/TickRewards.s.sol`
  - `contracts/script/rollup/AddRewards.s.sol`
- Operator primitives exist today under `contracts/script/ops/`:
  - `Rebalance.s.sol`
  - `UpdateAccounting.s.sol`
  These will be re-wrapped by new scripts under `contracts/script/local/` so end-users only need the `dev:local-*` yarn commands.

## Work Plan

### 1) Seed provider keys automatically during local deployment (no manual command)

Problem: staking requires provider keystores to exist; today keys are added via `contracts/script/provider/AddKeys.s.sol`, but the desired UX forbids a separate `dev:local-add-provider-keys` command.

Plan:

- Modify `contracts/script/Deploy.s.sol` (local mock path only, i.e. `if (config.deployMocks) { ... }`) to add an initial batch of deterministic dummy keystores right after deploying the staking stack.
- Reuse the same deterministic keystore generation approach as `contracts/script/provider/AddKeys.s.sol` (attester derived from `keccak256("olla-attester", i)`; fixed BN254 points).
- Call `StakingProviderRegistry(stakingProviderRegistry).addKeysToProvider(keys)` within the deploy broadcast (deployer key).
- Default key count: 5 (same as `AddKeys.s.sol`), optionally configurable via env var `PROVIDER_KEY_COUNT` (safe default if unset).

Acceptance:

- Right after `yarn deploy:local`, staking can succeed without any extra manual steps.

### 2) Add local user/god forge scripts under `contracts/script/local/`

Create:

1) `contracts/script/local/MintAztecTo.s.sol`

- Inputs:
  - `AMOUNT` (whole tokens, required)
  - `TO` (address, default anvil account-1)
  - optional `ASSET` override; otherwise read `Asset` from `deployments/<DEPLOY_ENV>.json`
- Action:
  - `IERC20Mintable(asset).mint(to, amount * 1e18)`

2) `contracts/script/local/UserDeposit.s.sol`

- Inputs:
  - `AMOUNT` (whole tokens, required)
  - optional `CORE`/`ASSET` overrides; otherwise read from `deployments/<DEPLOY_ENV>.json` (`OllaCoreProxy`, `Asset`)
- Signer:
  - user key (default anvil account-1 via `PRIVATE_KEY` passed by yarn)
- Action:
  - approve + `OllaCore(core).deposit(amountWei, recipient)` where recipient defaults to the broadcaster.

3) `contracts/script/local/OperatorRebalance.s.sol`

- Wrapper script that calls `OllaCore(core).rebalance()`.
- Signer:
  - operator key (default anvil account-0).

4) `contracts/script/local/UserInitiateWithdrawAll.s.sol`

- Reads `stAZTEC` from deployment (`StAztec`) and requests redeem for the broadcaster’s full balance.
- Action:
  - `shares = IERC20(stAztec).balanceOf(user)`
  - `OllaCore(core).requestRedeem(shares, recipient)` (recipient defaults to broadcaster).

5) `contracts/script/local/UserClaimWithdrawals.s.sol`

- Reads `uint256[] ids = IOllaCore(core).activeRequestIds(user)` and attempts to claim finalized ones.
- For each id:
  - if the queue says it’s finalized+unclaimed, call `claimRequestById(id)`.
- This turns “withdraw” into an end-to-end flow that returns AZTEC to the user wallet.

Notes:

- All scripts should follow the same conventions as existing scripts: `DEPLOY_ENV` default `local`, address resolution via deployments with env overrides (see `contracts/script/base/BaseScript.s.sol`).

### 3) Implement the continuous rewards mock-loop (term-2)

Add a small Node script (no dependencies) to continuously accrue rewards *only when there is rollup stake*.

Create:

- `scripts/local-mock-loop.js`

Loop behavior (every `INTERVAL_MS`, default 2000-5000ms):

1) Read staking-related addresses from `contracts/deployments/local.json`:
   - `StakingManager` (for `totalStaked()` gating)
   - (optional) `MockAztecRollup` + `RewardsVaultProxy` are already defaulted by existing forge scripts.
2) Query `totalStaked()` using `cast call`.
3) If `totalStaked > 0`:
   - ensure reward rate is set (one-time on startup): `forge script script/rollup/SetRewardRate.s.sol --broadcast` with `RATE` (default configurable)
   - tick rewards: `forge script script/rollup/TickRewards.s.sol --broadcast`
   - run operator upkeep:
     - `forge script script/ops/Rebalance.s.sol --broadcast` (or call the new `contracts/script/local/OperatorRebalance.s.sol` if preferred)
     - `forge script script/ops/UpdateAccounting.s.sol --broadcast` (or add a `local/OperatorUpdateAccounting.s.sol` wrapper)

Rationale:

- `MockAztecRollup.tick(coinbase)` accrues pending rewards based on elapsed time and `rewardRatePerSecond`.
- `OllaCore.rebalance()` harvests rollup rewards (via StakingManager) into RewardsVault, records them, finalizes withdrawals, and stakes/unstakes as needed.

### 4) Wire Yarn commands in `package.json`

Add scripts:

- `dev:local-start-mock-loop`: `node scripts/local-mock-loop.js`
- `dev:local-god-mint-user`: runs `forge script script/local/MintAztecTo.s.sol --broadcast --rpc-url http://127.0.0.1:8545` with `AMOUNT=$1` and defaults `TO` to anvil account-1
- `dev:local-user-deposit`: runs `forge script script/local/UserDeposit.s.sol --broadcast --rpc-url http://127.0.0.1:8545` with `AMOUNT=$1` and `PRIVATE_KEY` = anvil account-1
- `dev:local-operator-rebalance`: runs `forge script script/local/OperatorRebalance.s.sol --broadcast --rpc-url http://127.0.0.1:8545` with `PRIVATE_KEY` = anvil account-0
- `dev:local-user-initiate-withdraw-all`: runs `forge script script/local/UserInitiateWithdrawAll.s.sol --broadcast --rpc-url http://127.0.0.1:8545` with `PRIVATE_KEY` = anvil account-1
- `dev:local-user-claim-withdrawals`: runs `forge script script/local/UserClaimWithdrawals.s.sol --broadcast --rpc-url http://127.0.0.1:8545` with `PRIVATE_KEY` = anvil account-1

Environment knobs:

- `RATE` for reward rate (used by mock loop)
- `INTERVAL_MS` for loop frequency
- `PROVIDER_KEY_COUNT` for initial key seeding on deploy (optional)

### 5) Update docs

Update `contracts/script/docs/local.md` with:

- the 3-terminal workflow
- notes about defaults (anvil account-0 is deployer/operator, account-1 is user)
- the withdraw lifecycle: initiate -> operator rebalance(s) to finalize -> claim

## End-to-End Acceptance Checklist

- `yarn dev:chain` starts anvil.
- `yarn deploy:local` succeeds and produces `contracts/deployments/local.json` containing `Asset`, `OllaCoreProxy`, `StAztec`, `StakingManager`, `MockAztecRollup`, `RewardsVaultProxy`, `StakingProviderRegistryProxy`.
- Immediately after deploy, staking is possible (provider keys already present).
- `yarn dev:local-god-mint-user 200000` increases user AZTEC balance by `200000e18`.
- `yarn dev:local-user-deposit 200000` mints `stAZTEC` to the user and moves AZTEC into core.
- With the mock loop running, `yarn dev:local-operator-rebalance` (or automatic via loop) results in increasing rewards over time (visible via `contracts/script/ops/PrintState.s.sol`).
- `yarn dev:local-user-initiate-withdraw-all` enqueues withdrawal request(s) and burns all user `stAZTEC`.
- After operator rebalances finalize the queue, `yarn dev:local-user-claim-withdrawals` returns AZTEC to the user.
