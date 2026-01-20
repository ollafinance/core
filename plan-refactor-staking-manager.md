# Refactoring Plan

## Summary

Remove \_totalStakedPrincipal tracking, refactor unstaking to use effectiveBalance instead of getActivationThreshold, add getStakingState() function to report current balances, and improve validation in \_claimUnstakedFunds().

## Detailed Changes

### 1. Interface Updates (IStakingManager.sol)

- Refactor \_pendingUnstakeRequests, it should just be a list of attestor addresses
- Remove: totalStaked() function declaration
- Rename: \_pendingUnstakes to \_estimatedPendingUnstakes
- Rename getPendingUnstakes() to getEstimatedPendingUnstakes()
- Add: StakingState struct:
  struct StakingState {
  uint256 stakedAmount; // VALIDATING status
  uint256 pendingUnstakeAmount; // EXITING or ZOMBIE status, not yet exitable
  uint256 withdrawableAmount; // EXITING or ZOMBIE status, exitable now
  }
  - Add: getStakingState() function

### 1. State Management Changes (StakingManager.sol)

- Remove: Line 57 \_totalStakedPrincipal
- Remove: Lines 205-207 totalStaked() implementation
- Remove: Lines 286, 349 where \_totalStakedPrincipal is updated
- Keep: \_pendingUnstakes (needed for tracking)
- Keep: \_activatedAttesters and \_pendingUnstakeRequests lists

#### 1. New getStakingState() Function

First iterate through all attestors in \_activatedAttesters, query getAttesterView() for each:

- If status == VALIDATING: add effectiveBalance to stakedAmount
- If status == ZOMBIE:

  - remove attester from \_activatedAttesters and instead add to \_pendingUnstakeRequests

    Second iterate through all attestors in \_pendingUnstakeRequests, query getAttesterView() for each:
    require exit exists

  - If exitableAt > block.timestamp: add exit.amount to pendingUnstakeAmount
  - Else: add exit.amount to withdrawableAmount

- Note: effectiveBalance is only > 0 when VALIDATING; for EXITING/ZOMBIE states, funds are in exit.amount

#### 1. Refactor \_unstakeInternal()

REFINE BELOW LOGIC

1. There only needs to be one loop which breaks when enough funds are unstaked. (greater than or equal to requestedUnstakeAmount)
1. add estimatedPendingUnstakes update when unstake is initiated

New logic:

1. Get canonical rollup and initialize IAztecStaking
1. Loop through all attestors in \_activatedAttesters to:

   - Query getAttesterView(attester)
   - Calculate availableToUnstake sum (effectiveBalances of VALIDATING attestors)

1. Validate: amount <= availableToUnstake
1. Select attestors to unstake from by iterating and subtracting effectiveBalances until target reached
1. For each selected attester:

   - Call rollup.initiateWithdraw(attester, address(this))
   - Get updated AttesterView to retrieve exit.amount
   - Add address in \_pendingUnstakeRequests
   - Remove address from \_activatedAttesters

1. Emit events for each attester

#### 1. Refactor \_claimUnstakedFunds()

New logic:

1. Get canonical rollup and initialize IAztecStaking
1. Snapshot token balance before loop
1. Track sumOfExitAmounts while iterating through \_pendingUnstakeRequests:
   - Try rollup.finalizeWithdraw(attester)
   - On success: add exit.amount to sumOfExitAmounts, mark for removal
   - On failure: skip (not yet exitable)
1. Calculate claimed = balanceAfter - balanceBefore
1. Validate: sumOfExitAmounts == claimed
1. Update \_estimatedPendingUnstakes -= claimed
1. Remove attestors from \_pendingUnstakeRequests
1. Transfer claimed funds to CORE
1. Remove getActivationThreshold from unstake flow

### Key Insights from Codebase

- effectiveBalance > 0 only when status is VALIDATING
- When in EXITING or ZOMBIE state, funds are in exit.amount, not effectiveBalance
- After finalizeWithdraw, status becomes NONE and exit is deleted
- This means we can safely query attestors in \_activatedAttesters to get accurate state

### Clarifying Edge Cases

1. Attestors that are removed should not be re-added to provider queue
1. Slashing between query and usage of value is not an issue if it is within same function, because that is made within one transaction.
1. Zero-balance attestors: Could exist if slashing reduced balance to 0 but they haven't been ejected yet. Should skip these when selecting attestors for unstake.
