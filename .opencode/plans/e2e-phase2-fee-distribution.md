# Phase 2: Fee Minting and Distribution

**Risk**: Critical — protocol fees are computed from `grossRewards` and minted as new stAztec shares to treasury and provider. Errors here silently leak value (underpaying fees) or destroy holder value (overminting shares).

## Scope

Validate that:
- `_payoutOllaProtocolFees()` computes correct fee amounts from gross asset rewards
- `OllaVault.mintFees()` mints the correct stAztec shares to treasury and provider addresses
- The treasury/provider split matches `treasuryFeeSplitBP`
- Fee minting correctly dilutes existing holders proportionally
- Edge cases: zero rewards, zero feeBP, slashing negating rewards, multi-cycle accumulation

## Prerequisites

- OllaCore, OllaVault, WithdrawalQueue, StAztec (real, proxied)
- MockAccountingStakingManager (to simulate rewards and slashing)
- MockRewardsAccumulator (real mock — receives harvested rewards)
- SafetyModule (real or mock — not the focus here)
- OllaGovernance or direct governance address as owner

## Implementation Steps

### 1. Create test contract

```solidity
// contracts/test/e2e/FeeMintingDistribution.e2e.t.sol

contract FeeMintingDistributionE2ETest is Test {
    event OllaProtocolFeesPaid(uint256 feeAssets, uint256 treasuryShares, uint256 providerShares);
    event FeesMinted(uint256 treasuryShares, uint256 providerShares);

    // Full stack: core, vault, queue, stAztec, stakingManager, rewardsAccumulator, safetyModule
    // Use MockAccountingStakingManager for controlled reward injection
}
```

### 2. Reward simulation helper

```solidity
function _simulateRewards(uint256 amount) internal {
    // Set harvested amount on mock staking manager
    stakingManager.setHarvestedRewards(amount);
    // The mock mints tokens to rewardsAccumulator during harvestRewards()
}
```

### 3. Fee computation reference

The fee math in OllaCore (for assertion computation):

```
grossRewards = max(0, newTotalAssets - oldTotalAssets - netFlows)
feeAssets = grossRewards * protocolFeeBP / 10_000
feeShares = feeAssets * totalSupply / totalAssets  (floor division, pre-update rate)
treasuryShares = feeShares * treasuryFeeSplitBP / 10_000
providerShares = feeShares - treasuryShares
```

## Test Cases

### Test 2a: `test_FeeMinting_CorrectSharesAndDilution`

```
Setup:
  1. protocolFeeBP = 1000 (10%), treasuryFeeSplitBP = 5000 (50/50)
  2. alice deposits 100e18 → 100e18 stAztec (1:1)
  3. Full rebalance, stake surplus (e.g. targetBuffer = 0)

Actions:
  4. Simulate 20e18 rewards
  5. Warp past cooldown, full rebalance

Assertions:
  - grossRewards = 20e18
  - feeAssets = 2e18
  - feeShares = convertToShares(2e18) at pre-update rate = 2e18 * 100 / 100 = 2e18 shares
  - treasuryShares = 1e18
  - providerShares = 1e18
  - stAztec.balanceOf(treasury) == 1e18
  - stAztec.balanceOf(providerRewards) == 1e18
  - stAztec.totalSupply() == 102e18
  - totalAssets() == 120e18
  - alice's share value: 100e18 * 120 / 102 ~= 117.6e18 (net of fee dilution)
  - OllaProtocolFeesPaid(2e18, 1e18, 1e18) event emitted
  - FeesMinted(1e18, 1e18) event emitted on vault
```

### Test 2b: `test_FeeMinting_ZeroRewards_NoMint`

```
Setup:
  1. alice deposits 100e18, full rebalance (stake surplus)

Actions:
  2. Simulate 0 rewards
  3. Warp, full rebalance

Assertions:
  - stAztec.balanceOf(treasury) == 0
  - stAztec.balanceOf(providerRewards) == 0
  - stAztec.totalSupply() == 100e18 (unchanged)
  - No OllaProtocolFeesPaid event emitted (or emitted with 0s)
```

### Test 2c: `test_FeeMinting_ZeroFeeBP_NoMint`

```
Setup:
  1. Set protocolFeeBP = 0 via governance
  2. alice deposits 100e18, full rebalance

Actions:
  3. Simulate 10e18 rewards
  4. Full rebalance

Assertions:
  - stAztec.balanceOf(treasury) == 0
  - stAztec.balanceOf(providerRewards) == 0
  - totalAssets() == 110e18 (all rewards go to holders)
  - stAztec.totalSupply() == 100e18
  - alice share value == 110e18 (full rewards)
```

### Test 2d: `test_FeeMinting_MultiCycle_Accumulation`

```
Setup:
  1. protocolFeeBP = 500 (5%), treasuryFeeSplitBP = 7000 (70/30)
  2. alice deposits 1000e18, full rebalance (stake surplus)

Actions:
  3. Cycle 1: Simulate 50e18 rewards, rebalance
     Record: treasuryBal1, providerBal1, totalSupply1, totalAssets1, rate1
  4. Cycle 2: Simulate 30e18 rewards, rebalance
     Record: treasuryBal2, providerBal2, totalSupply2, totalAssets2, rate2
  5. Cycle 3: Simulate 0 rewards, rebalance
     Record: treasuryBal3, providerBal3, totalSupply3, totalAssets3, rate3

Assertions:
  - Cycle 1: fee = 50 * 5% = 2.5e18 assets
    feeShares1 = convertToShares(2.5e18) at pre-cycle rate (1:1) = 2.5e18
    treasuryDelta1 = 2.5e18 * 70% = 1.75e18
    providerDelta1 = 2.5e18 - 1.75e18 = 0.75e18
  - Cycle 2: fee = 30 * 5% = 1.5e18 assets
    feeShares2 = convertToShares(1.5e18) at rate1 (rate > 1 now)
    treasuryDelta2 = feeShares2 * 70% (computed at new rate)
    providerDelta2 = feeShares2 - treasuryDelta2
  - Cycle 3: no fees minted, balances unchanged
  - rate1 < rate2 < rate3 is NOT guaranteed (rate3 == rate2 since 0 rewards)
  - rate1 > 1 (rewards increased totalAssets)
  - rate2 > rate1 (more rewards)
  - totalAssets3 == 1000 + 50 + 30 = 1080e18
  - No value leakage: alice_value + treasury_value + provider_value == totalAssets
```

### Test 2e: `test_FeeMinting_WithSlashing_ReducedOrZeroFees`

```
Setup:
  1. protocolFeeBP = 1000 (10%)
  2. alice deposits 100e18, full rebalance (stake all, buffer = 0)

Actions:
  3. Simulate slashing: stakingManager.setSlashingDelta(15e18)
     Mock totalStaked reduced accordingly
  4. Simulate small reward: 5e18
  5. Full rebalance

Assertions:
  - grossRewards = max(0, newTotalAssets - oldTotalAssets - 0)
    newTotalAssets = stakedPrincipal - 15 + 5 + buffer = ~90e18
    oldTotalAssets = 100e18
    grossRewards = max(0, 90 - 100) = 0
  - No fees minted
  - Exchange rate dropped: rate < 1e18
  - totalAssets() ~= 90e18
```

## Acceptance Criteria

- [ ] Fee assets correctly computed as `grossRewards * protocolFeeBP / 10_000`
- [ ] Fee shares correctly converted at the pre-update exchange rate
- [ ] Treasury/provider split matches `treasuryFeeSplitBP` exactly
- [ ] `OllaProtocolFeesPaid` and `FeesMinted` events emitted with correct values
- [ ] Zero-reward and zero-feeBP cases produce no share minting
- [ ] Multi-cycle fee accumulation is consistent (no compounding errors)
- [ ] Slashing that negates rewards produces zero fees (not negative)
- [ ] Conservation: `alice_value + treasury_value + provider_value == totalAssets` (no leakage)

## Verification

```bash
forge test --match-contract FeeMintingDistributionE2ETest -vvv
```
