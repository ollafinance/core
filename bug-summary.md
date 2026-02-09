Here's the full diagnosis:
Root Cause: OllaCore re-stakes tokens earmarked for claims
The bug is in OllaCore itself, not the mocks. Here's the sequence:

1. User deposits 200k. Rebalance stakes it to the rollup. OllaCore balance ~= rewards only (~148 AZTEC).
2. User calls requestRedeem. WithdrawalQueue records a pending request for ~200,102 AZTEC.
3. Rebalance cycle A: \_initiateUnstake() calls stakingManager.unstake() -> rollup.initiateWithdraw(). Exit is created with exitableAt = block.timestamp (instant on mock).
4. Rebalance cycle B: \_pullUnstakedFunds() finalizes the exit, pulls ~200k from rollup -> StakingManager -> OllaCore. bufferedAssets += 200k. Then \_finalizeWithdrawals() sees bufferedAssets (~200,148) >= assetsExpected (~200,102), marks the request finalized: true, decrements bufferedAssets by ~200,102. Now bufferedAssets ≈ 46 but actual token balance ≈ 200,148 (finalized tokens stay in OllaCore until claimed).
5. Rebalance cycle C (the killer): \_syncBufferedWithBalance() sees actual (200,148) > buffered (46), reconciles upward to bufferedAssets = 200,148. Then \_stakeSurplus() sees surplus and re-stakes ~200,148 tokens, sending them to the StakingManager/rollup. The ~200,102 tokens earmarked for the user's claim are gone.
6. User calls claimRequestById -> safeTransfer(user, 200,102) -> reverts with ERC20InsufficientBalance because OllaCore only has ~170 AZTEC (accumulated rewards since re-staking).
   The missing piece: OllaCore has no reservedForClaims bucket. When \_finalizeWithdrawals decrements bufferedAssets, those tokens become "invisible" to accounting but are still physically in the contract. \_syncBufferedWithBalance treats them as unexpected surplus, and \_stakeSurplus sends them away.
