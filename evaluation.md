# Evaluation: `_processUnstakeAttester` False Return Branch

## Question

What case is this branch intended to handle?

```solidity
_setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
return 0;
```

This branch is reached only when all of the following are true:

1. The rollup view already has an exit for the attester.
2. The exit is a zombie exit (`isRecipient == false`).
3. `rollup.initiateWithdraw(attester, address(this))` returns `false` instead of reverting or returning `true`.

## Findings

The branch appears to be defensive handling for a hypothetical rollup behavior where `initiateWithdraw()` returns `false` when an exit already exists. The apparent intent was to avoid repeatedly selecting the same externally exited attester during rebalance by moving it from `Active` to `Exiting` and letting a later refresh reconcile the exit.

However, this case does not appear reachable on the current Aztec rollup implementation.

In Aztec 4.0.0, `StakingLib.initiateWithdraw()` either reverts or returns `true`:

```solidity
if (store.exits[_attester].exists) {
  require(!store.exits[_attester].isRecipient, Errors.Staking__NothingToExit(_attester));
  require(
    store.exits[_attester].recipientOrWithdrawer == msg.sender,
    Errors.Staking__NotWithdrawer(store.exits[_attester].recipientOrWithdrawer, msg.sender)
  );
  store.exits[_attester].recipientOrWithdrawer = _recipient;
  store.exits[_attester].isRecipient = true;

  emit IStakingCore.WithdrawInitiated(_attester, _recipient, store.exits[_attester].amount);
} else {
  ...
}

return true;
```

For a zombie exit, the registered withdrawer can call `initiateWithdraw()` to set the final recipient. If that succeeds, the function returns `true`. If the caller is not the withdrawer, the exit is already recipient-claimed, the attester has no balance, or another precondition fails, the function reverts.

The local `MockAztecRollup` follows the same pattern: zombie exits return `true` after being claimed, and invalid cases revert. The only test exercising a `false` return uses `vm.mockCall(... abi.encode(false))`, so it is not evidence of a real Aztec state transition.

## Accounting Impact If Reachable

If this branch were reachable, the local accounting would be incomplete.

It only changes the local attester status:

```solidity
_setAttesterStatus(attester, info, InternalAttesterStatus.Exiting);
return 0;
```

It does not:

1. Set `info.exitRollup`.
2. Set `info.pendingExitAmount`.
3. Clear or reduce `info.stakedAmount`.
4. Remove the cached stake from `_aggregateState.stakedAmount`.
5. Add the recoverable `exit.amount` to `_aggregateState.pendingUnstakeAmount`.
6. Record any slashing gap in `_aggregateState.slashingDelta`.

That means an attester could be moved out of the active set without the same accounting reconciliation performed by `_finalizeUnstakeInitiation()`. This would create inconsistent local state if a future or non-standard rollup returned `false` instead of reverting.

## Conclusion

The branch was likely intended as a liveness fallback for an assumed `false` return from `initiateWithdraw()` when an exit already exists. Based on the current Aztec implementation, that case is not reachable: successful calls return `true`; unsuccessful calls revert.

Because the branch is unreachable on current Aztec and incomplete if it ever becomes reachable, it should not remain as-is.

## Recommendation

Prefer removing the special `false` handling and treating `!isInitiated` as an unstake failure, matching the no-exit path.

If defensive compatibility with future/non-standard rollups is desired, then the `false` branch should perform full local reconciliation before returning. At minimum, it should snapshot `exitRollup`, snapshot `pendingExitAmount`, move the recoverable `exit.amount` into aggregate pending unstakes, remove the cached stake from aggregate staked amount, clear `info.stakedAmount`, and record the slashing delta when `cachedStake > exitAmount`.

Given the current Aztec behavior, the simpler and safer resolution is to revert on `!isInitiated`.

## Suggested Auditor Response

The branch was originally intended as defensive handling for a hypothetical rollup response where `initiateWithdraw()` returns `false` despite an exit already existing, allowing Olla to stop selecting the attester as Active during rebalance. After reviewing the current Aztec 4.0.0 implementation, this case is not reachable: `initiateWithdraw()` returns `true` on successful zombie-exit claiming and reverts on failure. We agree that if such a `false` return were reachable, the branch would be incomplete because it does not snapshot `exitRollup`, `pendingExitAmount`, or reconcile aggregate accounting. The intended fix is to remove this fallback or change it to revert on `false`; if future-rollup compatibility is desired, the branch must perform the same accounting finalization as a successful initiation.
