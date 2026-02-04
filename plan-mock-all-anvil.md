# Plan: Mock Aztec Parts On Local Anvil (Realistic Rebalance/Accounting)

Goal: run an anvil-local deployment that is as close to reality as possible, with only the Aztec contracts mocked, such that:
- `OllaCore.rebalance()` harvests sequencer rewards through `StakingManager.harvestRewards()` -> `rollup.claimSequencerRewards(RewardsVault)`.
- harvested rewards materialize as an actual ERC20 balance increase in `RewardsVault` so `RewardsVault.recordBalance()` produces a non-zero delta.
- claimable rewards grow over time for UI purposes (constant increase), and can be sped up/controlled by an operator script.
- rewards growth can also be influenced by unstake initiation (`rollup.initiateWithdraw`) without trying to make it harvestable in the same rebalance call.
- stake withdrawals pay out to the one staking/withdrawing (`StakingManager`).

Constraints:
- No "same-call" harvest after `initiateWithdraw` (rebalance ordering stays as-is).
- Only use/extend `contracts/src/staking/mocks/MockAztecRollup.sol` (no new rollup mock).
- Update `MockAztecRollup.sol` and any impacted tests accordingly.

## Architecture (Real Contracts vs Mocked Aztec)

Real protocol contracts:
- `OllaCore` (core vault + accounting)
- `RewardsVault` (delta accounting based on actual token balance)
- `StakingManager` (calls rollup, manages attesters, initiates/finalizes stake withdrawals)
- `StakingProviderRegistry` (attester key queue, provider config)
- `WithdrawalQueue`, `StAztec`, `SafetyModule` (existing local-safe choices)

Mocked Aztec-side:
- `MockAztecRollup` (extended to support time-based + event-based rewards accrual)
- `MockAztecRollupRegistry` (returns canonical rollup)

Rewards/staking asset:
- `MockAztec` (mintable ERC20; easiest for mint-on-cadence)

Payment semantics to enforce:
- Rewards payout: `claimSequencerRewards(coinbase)` MUST pay `coinbase` (RewardsVault address in our protocol).
- Stake withdrawal payout: `finalizeWithdraw(attester)` transfers the stake to the stored exit recipient (StakingManager in our protocol).

## MockAztecRollup: Required Changes

### 1) Fix reward payout target (bugfix)

Current incorrect behavior: `claimSequencerRewards` transfers to `msg.sender`.

Correct behavior:
- `claimSequencerRewards(coinbase)` pays `coinbase`.
- Clear `pendingRewards[coinbase]` after claim.
- Return the claimed amount.

Implementation direction:
- Prefer mint-on-claim using `MockAztec.mint(coinbase, amount)` (simplest; no prefunding required).

### 2) Add reward accrual suitable for UI + operator control

We want rewards to increase steadily and be controllable without modifying protocol code.

State (minimum):
- `uint256 public rewardRatePerSecond;`
- `uint256 public lastTick;`
- `mapping(address => uint256) public pendingRewards;` (already exists)

Functions:
- `tick(coinbase)` (recommended):
  - compute `dt = block.timestamp - lastTick`.
  - increment `pendingRewards[coinbase] += rewardRatePerSecond * dt`.
  - set `lastTick = block.timestamp`.
- `setRewardRatePerSecond(newRate)` (dev convenience; keep permissioning simple for local).
- Optional convenience:
  - `addRewards(coinbase, amount)` (instant bump).
  - keep existing `setRewards(coinbase, amount)` as an override lever.

Coinbase target:
- In our protocol, `coinbase == RewardsVault` address.
- Prefer explicit `tick(coinbase)` for clarity and script ergonomics.

### 3) Tie rewards to unstake initiation (depend on `initiateWithdraw`)

Add an optional bump to rewards when `initiateWithdraw` is called.

Baseline version:
- On `initiateWithdraw(attester, recipient)`:
  - compute `amount = stakes[attester]`.
  - bump `pendingRewards[RewardsVault]` by a function of `amount`.

Start with:
- bump amount equals activation threshold (i.e. `amount`), as a simple first model.
- Later upgrade to `amount * withdrawRewardBps / 10_000` (configurable) if needed.

This ensures:
- claimable increases immediately when unstakes are initiated.
- harvest happens on the next `rebalance()` (since `rebalance()` harvestes before initiating unstakes).

### 4) Activation threshold defaults

- Default activation threshold for the mock rollup: `200_000e18` (MockAztec uses 18 decimals).
- Keep existing `setActivationThreshold` helper so scripts/tests can change it.

## Local Deployment & Wiring (Anvil + Forge Script)

### Desired local deployment graph

- Deploy `MockAztec` as the staking/reward asset.
- Deploy `MockAztecRollup` with activation threshold = `200_000e18`.
- Deploy `MockAztecRollupRegistry` pointing to the rollup.
- Deploy `StakingManager` (proxy) initialized with:
  - `stakingAsset = MockAztec`
  - `rollupRegistry = MockAztecRollupRegistry`
  - `rewardsVault = RewardsVault`
  - `core = OllaCoreProxy`
  - `stakingProviderRegistry = StakingProviderRegistryProxy`
- Deploy `StakingProviderRegistry` (proxy) initialized with:
  - `stakingManager = StakingManagerProxy`
  - provider admin + rewards recipient as local addresses (deployer by default)
- Deploy `RewardsVault` (proxy) with:
  - `rewardsToken = MockAztec`
  - `core = OllaCoreProxy`
- Deploy `OllaCore` (proxy) initialized with:
  - `asset = MockAztec`
  - `stakingManager = StakingManagerProxy`
  - `rewardsVault = RewardsVaultProxy`
  - keep existing local wiring for `WithdrawalQueue`, `SafetyModule`, `StAztec`

### Update local deploy scripts

- Replace the local "mock staking manager" deployment path with the real `StakingManager` + real `StakingProviderRegistry` + rollup/registry mocks.
- Ensure deployment JSON writes actual addresses after they are known.

## Operator / Cron Scripts (Forge)

Provide scripts that work without UI and are UI-friendly.

Core operator scripts:
- `rebalance`: calls `OllaCore.rebalance()` as an address with `OPERATOR_ROLE`.
- `updateAccounting`: calls `OllaCore.updateAccounting()` as operator.
- `grantOperator`: grants operator role to a chosen EOA (local convenience).

Rollup control scripts:
- `tickRewards`: calls `MockAztecRollup.tick(RewardsVault)` (cron target).
- `setRewardRate`: sets `rewardRatePerSecond`.
- `addRewards`: instant bump (optional).
- `setActivationThreshold`: for fast testing (optional).

Provider scripts:
- `addKeys`: adds N dummy keystores to `StakingProviderRegistry` (so stake can happen once stake surplus is implemented).

Cron workflow example:
- Terminal A: `anvil`
- Terminal B: deploy via `forge script` (local deploy)
- Terminal C (cron): loop calling `tickRewards` every N seconds
- Terminal D (operator): run `rebalance`/`updateAccounting` manually or periodically

## Expected Runtime Behavior (Sanity Checks)

- Claimable rewards increases:
  - `rollup.getSequencerRewards(RewardsVault)` grows when `tick()` is called.
- Harvesting on rebalance:
  - `OllaCore.rebalance()` calls `stakingManager.harvestRewards()`.
  - `stakingManager.harvestRewards()` calls `rollup.claimSequencerRewards(RewardsVault)`.
  - rollup mints/transfers MockAztec directly to `RewardsVault`.
  - `RewardsVault.recordBalance()` returns a delta > 0.
- Unstake reward dependency:
  - `rebalance()` triggers `stakingManager.unstake()` which calls `rollup.initiateWithdraw(...)`.
  - rollup bumps `pendingRewards[RewardsVault]` based on activation threshold.
  - next `rebalance()` harvests that bumped amount.

## Test Updates

Because `MockAztecRollup.claimSequencerRewards` payout target is corrected:
- Update/repair any tests that assumed vault balances didn't change or that rewards were transferred to the staking manager.
- Add/adjust tests to assert:
  - rewards are minted/transferred to RewardsVault on claim.
  - `RewardsVault.recordBalance()` can observe the delta after a harvest in integration-style flows.
  - `initiateWithdraw` creates an additional claimable bump (if implemented).

## Implementation Order (High-Level)

1) Fix `MockAztecRollup.claimSequencerRewards` payout target and adjust tests until green.
2) Extend `MockAztecRollup` with `tick` + rate config + optional withdraw bump.
3) Update local deploy scripts to deploy real staking stack + rollup mocks (no mock staking manager).
4) Add forge scripts for:
   - rollup tick/rate controls
   - operator rebalance/accounting
   - provider key seeding
5) Quick end-to-end local demo:
   - deploy
   - seed provider keys
   - deposit + stake surplus (once implemented)
   - run tick cron
   - call rebalance and observe RewardsVault balance / accounting deltas

## Defaults

- Use `MockAztec` mint-on-claim for rewards.
- Default activation threshold: `200_000e18`.
- Start withdraw bump as a simple bump based on the activation threshold.
