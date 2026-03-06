# Phase 4: Instant Redemption + Async Withdrawal Queue Coexistence

**Risk**: High — `instantRedeem()` drains the vault buffer, which is the same pool used to finalize async withdrawal requests during rebalance. Concurrent use creates buffer contention that can leave the queue unfundable or cause accounting mismatches.

## Scope

Validate that:
- Instant redemption correctly reduces `_bufferedAssets` and applies the fee to treasury
- Reduced buffer after instant redemption limits how many queue requests can finalize
- Head-of-line blocking in the queue works correctly when buffer is insufficient
- Fee calculation is correct at exchange rates > 1
- Users can mix instant and async redemption in the same block
- Insufficient buffer reverts cleanly (no partial state changes)

## Prerequisites

- OllaCore, OllaVault, WithdrawalQueue, StAztec (real, proxied)
- MockAccountingStakingManager (to control staking and unstake returns)
- MockRewardsAccumulator
- SafetyModule (real or mock)

## Implementation Steps

### 1. Create test contract

```solidity
// contracts/test/e2e/InstantRedeemAsyncQueue.e2e.t.sol

contract InstantRedeemAsyncQueueE2ETest is Test {
    event InstantRedemption(
        address indexed owner, address indexed recipient,
        uint256 shares, uint256 grossAssets, uint256 fee, uint256 netAssets, uint256 rate
    );
    event WithdrawalFinalized(uint256 indexed id, uint256 assets);

    // Full stack with real WithdrawalQueue
    // Set instantRedemptionFeeBP in setUp
}
```

### 2. Key state tracking helpers

```solidity
function _vaultBuffer() internal view returns (uint256) {
    return asset.balanceOf(address(vault)) - withdrawalQueue.totalFinalizedUnclaimed();
    // OR use vault.availableForInstantRedemption() if exposed
}
```

### 3. Instant redeem fee setup

```solidity
// In setUp() or via governance:
// Set instantRedemptionFeeBP = 500 (5%)
// The vault applies: fee = grossAssets * 500 / 10_000
// Net to user = grossAssets - fee
// Fee sent to treasury as raw asset tokens (NOT stAztec shares)
```

## Test Cases

### Test 4a: `test_InstantRedeem_ReducesBufferAvailableForQueue`

```
Setup:
  1. alice deposits 100e18 (buffer = 100e18)
  2. bob deposits 50e18 (buffer = 150e18)
  3. instantRedemptionFeeBP = 100 (1%)

Actions:
  4. alice requests async redeem of 80e18 shares
  5. bob instant redeems 60e18 shares
     → grossAssets = 60e18, fee = 0.6e18, net = 59.4e18
  6. Warp, rebalance

Assertions:
  - After step 5: buffer = 150 - 60 = 90e18
  - asset.balanceOf(bob) == 59.4e18
  - asset.balanceOf(treasury) == 0.6e18 (fee)
  - After step 6: alice's request finalized (80e18 < 90e18 available)
  - Resulting buffer = 90 - 80 = 10e18
```

### Test 4b: `test_InstantRedeem_ExhaustsBuffer_QueueCannotFinalize`

```
Setup:
  1. alice deposits 100e18 (buffer = 100e18)
  2. instantRedemptionFeeBP = 0 (for simplicity)

Actions:
  3. alice requests async redeem of 50e18 shares
  4. bob deposits 10e18 (buffer = 110e18, but bob only has 10e18)
  5. alice instant redeems 95e18 shares → grossAssets = 95e18
     (alice has 100-50=50 shares left? No — requestRedeem burns shares)
     Correct: alice has 50 shares remaining after requesting 50
     alice instant redeems 45e18 shares → buffer = 110 - 45 = 65e18
     OR: have a third user do the instant redeem

Revised:
  1. alice deposits 100e18 (buffer = 100)
  2. bob deposits 100e18 (buffer = 200)
  3. alice requests async redeem of 80e18 shares (async, shares burned)
  4. bob instant redeems 180e18 shares → grossAssets = 180e18
     buffer = 200 - 180 = 20e18
  5. Warp, rebalance → finalize tries 80e18 but only 20e18 available

Assertions:
  - alice's withdrawal request NOT finalized (head-of-line: 80 > 20)
  - withdrawalQueue.getRequest(requestId).finalized == false
  - Rebalance completes to Done (queue left unfinalized is not an error)
  - buffer == 20e18 (nothing consumed by finalization)

Follow-up:
  6. Simulate unstaked funds returning (80e18)
  7. Rebalance → finalize succeeds
  8. alice claims → receives 80e18
```

### Test 4c: `test_InstantRedeem_FeeGoesToTreasury`

```
Setup:
  1. alice deposits 100e18
  2. instantRedemptionFeeBP = 500 (5%)
  3. Exchange rate = 1:1

Actions:
  4. alice instant redeems 20e18 shares
     → grossAssets = 20e18
     → fee = 1e18
     → netAssets = 19e18

Assertions:
  - asset.balanceOf(alice) == 19e18
  - asset.balanceOf(treasury) == 1e18
  - vault buffer = 80e18 (100 - 20 gross)
  - stAztec.totalSupply() == 80e18 (20 burned)
  - InstantRedemption event: (alice, alice, 20e18, 20e18, 1e18, 19e18, 1e18)
```

### Test 4d: `test_InstantRedeem_AfterRateIncrease_CorrectConversion`

```
Setup:
  1. alice deposits 100e18, full rebalance (stake surplus)
  2. Simulate 25e18 rewards, full rebalance
     → rate = totalAssets / supply = 125/102.x (after fees) ≈ ~1.22

Actions:
  3. Record rate = core.exchangeRate()
  4. bob deposits 50e18 → gets shares = 50e18 / rate
  5. bob instant redeems ALL his shares
     → grossAssets = bob_shares * rate (back to ~50e18 minus rounding)
     → fee = grossAssets * instantRedemptionFeeBP / 10_000
     → net = grossAssets - fee

Assertions:
  - bob received correct net assets based on current rate
  - bob received LESS than 50e18 (paid the fee)
  - Vault buffer accounting correct: buffer decreased by grossAssets
  - stAztec supply back to pre-bob level
```

### Test 4e: `test_InstantRedeem_InsufficientBuffer_Reverts`

```
Setup:
  1. alice deposits 100e18
  2. Full rebalance stakes 90e18 (buffer = 10e18, targetBuffer = 10e18)

Actions:
  3. alice tries instant redeem of 20e18 shares
     → grossAssets = 20e18 > buffer 10e18

Assertions:
  - vm.expectRevert: OllaVault__InsufficientLiquidity(20e18, 10e18)
  - No state changes (shares not burned, buffer unchanged)
```

### Test 4f: `test_InstantAndAsyncRedeem_SameUser_SameBlock`

```
Setup:
  1. alice deposits 200e18 → 200e18 stAztec
  2. instantRedemptionFeeBP = 500 (5%)

Actions (same block, no vm.warp between):
  3. alice instant redeems 50e18 shares
     → grossAssets = 50e18, fee = 2.5e18, net = 47.5e18
     → buffer = 200 - 50 = 150e18
     → alice shares = 150e18
  4. alice requests async redeem 50e18 shares
     → shares burned, enqueued with assetsExpected = 50e18
     → alice shares = 100e18

Assertions after step 4:
  - stAztec.balanceOf(alice) == 100e18
  - asset.balanceOf(alice) == 47.5e18 (from instant redeem)
  - buffer == 150e18
  - withdrawalQueue pending == 50e18

Follow-up:
  5. Warp, rebalance → finalize
  6. alice claims request → receives 50e18
  7. Total alice received = 47.5 + 50 = 97.5e18
     Total alice spent = 200e18 deposited
     Total alice still holds = 100e18 shares worth 100e18 at 1:1
     Check: 97.5 + 100 + 2.5 (fee) = 200 ✓
```

## Acceptance Criteria

- [ ] Instant redemption correctly reduces `_bufferedAssets` by `grossAssets` (not net)
- [ ] Fee computed as `grossAssets * instantRedemptionFeeBP / 10_000` transferred to treasury
- [ ] Net assets after fee transferred to recipient
- [ ] Buffer reduction limits queue finalization in subsequent rebalance
- [ ] Head-of-line blocking: large unfundable request blocks smaller requests behind it
- [ ] Insufficient buffer reverts with `OllaVault__InsufficientLiquidity` — no partial state change
- [ ] Mixed instant + async redemption in same block produces correct accounting
- [ ] Exchange rate > 1 correctly converts shares to assets for instant redemption
- [ ] Conservation: total_assets_out + fees + remaining_share_value == total_assets_in

## Verification

```bash
forge test --match-contract InstantRedeemAsyncQueueE2ETest -vvv
```
