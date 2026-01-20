# Refactoring Plan

## Summary

Remove \_totalStakedPrincipal tracking, refactor unstaking to use effectiveBalance instead of getActivationThreshold, add getStakingState() function to report current balances, and improve validation in \_claimUnstakedFunds().

## Detailed Changes

### 1. Interface Updates (IStakingManager.sol)

- Remove: totalStaked() function declaration
- Rename: getPendingUnstakes() to getEstimatedPendingUnstakes()
- Add: StakingState struct:
  ```solidity
  struct StakingState {
      uint256 stakedAmount; // VALIDATING status
      uint256 pendingUnstakeAmount; // EXITING or ZOMBIE status, not yet exitable
      uint256 withdrawableAmount; // EXITING or ZOMBIE status, exitable now
  }
  ```
- Add: getStakingState() function
- Note: UnstakeRequest struct is kept for interface compatibility but not used in \_pendingUnstakeRequests

### 2. State Management Changes (StakingManager.sol)

- Remove: Line 57 \_totalStakedPrincipal
- Remove: Lines 205-207 totalStaked() implementation
- Remove: Lines 286, 349 where \_totalStakedPrincipal is updated
- Rename: Line 60 \_pendingUnstakes to \_estimatedPendingUnstakes
- Refactor: Line 72 \_pendingUnstakeRequests from UnstakeRequest[] to address[] (only store attester addresses, query exit.amount from rollup when needed)
- Keep: \_activatedAttesters list
- Keep: \_isUnstakePending mapping (still needed for quick lookups)

#### 2.1 New getStakingState() Function

Iterate through all attestors in \_activatedAttesters, query getAttesterView() for each:

- If status == VALIDATING: add effectiveBalance to stakedAmount
- If status == ZOMBIE or status == EXITING:
  - Note: ZOMBIE/EXITING attestors can exist in \_activatedAttesters if they transitioned after stake
  - If exitableAt > block.timestamp: add exit.amount to pendingUnstakeAmount
  - Else: add exit.amount to withdrawableAmount

Then iterate through all attestors in \_pendingUnstakeRequests, query getAttesterView() for each:
- Require exit.exists == true
- If exitableAt > block.timestamp: add exit.amount to pendingUnstakeAmount
- Else: add exit.amount to withdrawableAmount

Note: effectiveBalance is only > 0 when VALIDATING; for EXITING/ZOMBIE states, funds are in exit.amount

#### 2.2 Refactor \_unstakeInternal()

Single-loop logic that breaks when enough funds are unstaked:

1. Get canonical rollup and initialize IAztecStaking
1. Initialize totalUnstakedAmount = 0
1. Iterate through \_activatedAttesters (from index 0 upward):
   - Query getAttesterView(attester)
   - Skip if status != VALIDATING or effectiveBalance == 0
   - If (totalUnstakedAmount + effectiveBalance >= amount):
     - This is the last attester we need to unstake from
     - Call rollup.initiateWithdraw(attester, address(this))
     - Query getAttesterView(attester) to get exit.amount (this matches the effectiveBalance at time of initiation)
     - Add exit.amount to totalUnstakedAmount and \_estimatedPendingUnstakes
     - Remove attester from \_activatedAttesters (swap-and-pop at current index)
     - Add attester to \_pendingUnstakeRequests
     - Emit UnstakeInitiated(attester, exit.amount) (use actual exit.amount, not estimated)
     - Break loop
   - Else:
     - We need more funds, keep unstaking from this attester
     - Call rollup.initiateWithdraw(attester, address(this))
     - Query getAttesterView(attester) to get exit.amount
     - Add exit.amount to totalUnstakedAmount and \_estimatedPendingUnstakes
     - Remove attester from \_activatedAttesters (swap-and-pop, decrement index since we swapped)
     - Add attester to \_pendingUnstakeRequests
     - Emit UnstakeInitiated(attester, exit.amount) (use actual exit.amount, not estimated)
1. After loop: if totalUnstakedAmount < amount, revert with StakingManager__InsufficientStake (should only happen due to slashing/zero-balance attestors)

#### 2.3 Refactor \_claimUnstakedFunds()

New logic:

1. Get canonical rollup and initialize IAztecStaking
1. Snapshot token balance before loop
1. Track sumOfExitAmounts while iterating through \_pendingUnstakeRequests:
   - Query getAttesterView(attester) to get exit.amount (must do this BEFORE finalizeWithdraw, as exit is deleted after)
   - Try rollup.finalizeWithdraw(attester)
   - On success: add exit.amount to sumOfExitAmounts, mark attester for removal
   - On failure: skip (not yet exitable)
1. Calculate claimed = balanceAfter - balanceBefore
1. Validate: sumOfExitAmounts == claimed (ensures all exit amounts match token transfers)
1. Update \_estimatedPendingUnstakes -= claimed
1. Remove successfully finalized attestors from \_pendingUnstakeRequests
1. Transfer claimed funds to CORE

### Key Insights from Codebase

- effectiveBalance > 0 only when status is VALIDATING
- When in EXITING or ZOMBIE state, funds are in exit.amount, not effectiveBalance
- After finalizeWithdraw, status becomes NONE and exit is deleted
- This means we can safely query attestors in \_activatedAttesters to get accurate state

### Clarifying Edge Cases

1. Attestors that are removed should not be re-added to provider queue
1. Slashing between query and usage of value is not an issue if it is within same function, because that is made within one transaction.
1. Zero-balance attestors: Could exist if slashing reduced balance to 0 but they haven't been ejected yet. Should skip these when selecting attestors for unstake.

## Implementation Checklist

### IStakingManager.sol
- [ ] Remove totalStaked() function declaration
- [ ] Rename getPendingUnstakes() to getEstimatedPendingUnstakes()
- [ ] Add StakingState struct
- [ ] Add getStakingState() function declaration

### StakingManager.sol
- [ ] Remove \_totalStakedPrincipal state variable (line 57)
- [ ] Rename \_pendingUnstakes to \_estimatedPendingUnstakes (line 60)
- [ ] Refactor \_pendingUnstakeRequests from UnstakeRequest[] to address[] (line 72)
- [ ] Remove totalStaked() function implementation (lines 205-207)
- [ ] Update \_stakeInternal(): remove \_totalStakedPrincipal update (line 286)
- [ ] Implement getStakingState() function
- [ ] Implement getEstimatedPendingUnstakes() function (renamed from getPendingUnstakes())
- [ ] Refactor \_unstakeInternal() to use single-loop logic with effectiveBalance
- [ ] Refactor \_claimUnstakedFunds() to validate sumOfExitAmounts == claimed
- [ ] Update UnstakeInitiated event to emit actual exit.amount

## Testing Considerations

After implementing these changes, ensure the following test scenarios pass:
- getStakingState() correctly reports staked/pending/withdrawable amounts
- Unstaking with varying effectiveBalances due to slashing works correctly
- Claiming unstaked funds validates sumOfExitAmounts == claimed
- Zero-balance attestors are properly skipped during unstake
- getEstimatedPendingUnstakes() matches the sum of exit.amount values
- Total unstaked amount equals the sum of all emitted UnstakeInitiated amounts
- State consistency is maintained throughout stake/unstake/claim cycles
