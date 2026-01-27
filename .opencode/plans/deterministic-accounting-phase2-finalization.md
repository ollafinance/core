# Phase 2: Deterministic Accounting Finalization

**Issue**: #58 - feat: Deterministic accounting finalization

## Scope

- Recompute `totalAssets` deterministically from on-chain sources.
- Compute `exchangeRate` using total assets and stAztec supply.
- Compute `grossRewards` and protocol fee base using net flows.
- Apply floor-based rounding for shares and fee minting.

## Prerequisites

- Phase 1 complete (validator deltas and accounting inputs available).
- Fee configuration and minting targets defined in issue #46 (RewardsVault + fee distribution).

## Implementation Steps

1. **Compute net flows correctly**
   - Use cumulative deposits/withdrawals to calculate net flows.
   - Use signed math so `netFlows = netDeposits - netWithdrawals` can be negative; compute `grossRewards` per spec and mint fees whenever `grossRewards > 0`.

2. **Deterministic total assets**
   - Use the on-chain buckets from Phase 1:

```solidity
totalAssets = bufferedAssets
    + stakedPrincipal
    + rewardsVaultBalance
    + rewardsDelta
    - slashingDelta;
```

3. **Exchange rate computation**
   - `exchangeRate = totalAssets * 1e18 / stAztec.totalSupply()` with floor rounding.
   - If supply == 0, set rate to `1e18` (per `operations-and-controls.md`).

4. **Gross rewards and fee shares**
   - `grossRewards = (newTotalAssets - oldTotalAssets) - netFlows` (if positive; else zero).
   - Defer feeBps/treasurySplitBps wiring to the RewardsVault feature; keep fee math scaffolded so it can plug into configured values later.

5. **Fee minting targets**
   - Defer treasury/provider minting wiring to the RewardsVault feature unless existing interfaces already expose targets.

6. **Update reporting snapshots**
   - Store `LatestReport` with new totals, rate, grossRewards, netFlows, timestamp.
   - Emit `AccountingUpdated` with fee fields populated.

## Test Cases from Issue

- [ ] `totalAssets` recomputation matches formula across deposits and withdrawals.
- [ ] Floor rounding applied consistently.
- [ ] SafetyModule checks invoked with expected inputs. (Assertions can be mocked here or in Phase 3 integration tests.)

## Acceptance Criteria

- [ ] Accounting uses only on-chain data sources listed above.
- [ ] Exchange rate update and fee minting are deterministic.

## Verification

```bash
forge test --match-path "contracts/test/core/OllaCore.t.sol"
```
