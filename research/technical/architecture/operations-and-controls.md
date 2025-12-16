# Operations and Safety Controls

## Operational cadence

### Daily
- Check buffer size, queue, TVL.
- If `bufferedAssets > targetBuffer` and not paused: call `rebalance()` (harvest rewards, pull unstaked funds, finalize withdrawals, stake surplus).
- Call `updateAccounting()` at least daily (can combine with `rebalance()`):
  - Query `AztecRollupContract` for validator state.
  - Run safety checks on rewards and slashing deltas.
  - Update `exchangeRate` and mint protocol fees.

### Weekly
- Check TVL vs `depositCap` in `SafetyModule`.
- Check `withdrawalQueue.totalPendingAssets / totalAssets` vs `maxQueueRatioBps`.
- Verify `checkAccountingLiveness()` has not tripped.
- Inspect validator performance and any slashing events.

## Security and risk controls

**Initial conditions**
- If `totalSupply == 0`, `exchangeRate = 1e18`.
- First deposit mints `assets * 1e18` shares.

**Rounding policy**
- Mint or burn operations round in the user’s favor (floor-based).
- Dust is retained by the protocol treasury.

**Under-collateralization**
- If `totalAssets < sum(all locked withdrawal amounts)`:
  1. SafetyModule triggers circuit breaker and pauses deposits.
  2. Withdrawal finalization waits for assets to become available.
  3. Guardian investigates and defines recovery path.

**Circuit breaker handling**
- SafetyModule sets `paused = true` and emits the reason.
- GuardianMultisig is alerted off-chain and decides whether to adjust parameters, stay paused, or unpause.

**Slashing event**
- Reflected in `AztecRollup.getValidatorState()` as `slashingDelta`.
- `updateAccounting()` includes the delta and may trigger SafetyModule thresholds; guardian decides restart parameters or provider replacement.

**Accounting failure**
- If `updateAccounting()` is stale beyond `maxAccountingDelay`, `checkAccountingLiveness()` pauses the protocol.
- Deposits disabled; withdrawal requests allowed; finalization disabled; claims of finalized withdrawals allowed.

**Paused state behavior**
- Deposits: disabled.
- Withdrawal requests: allowed.
- Finalization: disabled.
- Claims of finalized withdrawals: allowed.

