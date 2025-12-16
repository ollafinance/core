# Liquid Staking Mechanics (V1)

This doc summarizes how Olla V1 works at a protocol level. Detailed specs live in `research/technical/architecture/`.

## Overview
Olla lets users stake Aztec to a single trusted validator while holding a non-rebasable receipt token (`stAztec`). OllaCore coordinates deposits, withdrawals, staking, accounting, and safety. StAztec supply changes only via mint/burn in OllaCore.

## Core mechanics

### Deposits
- User calls `OllaCore.deposit(assets, receiver)`.
- SafetyModule checks caps and paused state.
- Shares minted in `stAztec` at the current `exchangeRate` and sent to `receiver`.
- `bufferedAssets` increases; no immediate staking is required.

### Withdrawal requests and claims
- User calls `OllaCore.requestWithdrawal(shares, receiver)`.
- OllaCore burns the shares and locks `assetsExpected = shares * exchangeRate` in `WithdrawalQueue` (FIFO).
- Later, after operator finalizes, user calls `claim(requestId)` and receives the locked assets.

### Rebalance (operator-only)
Single entrypoint that may:
1. Harvest sequencer rewards via `StakingManager` -> `RewardsVault`.
2. Pull matured unstakes into OllaCore.
3. Finalize withdrawals in FIFO until liquidity is insufficient.
4. Stake any surplus above `targetBuffer` via `StakingManager` using queued validator keys.

### Accounting (operator-only)
- `updateAccounting()` rebuilds `newTotalAssets` from buffered assets, staked principal, RewardsVault balance, and rollup-reported deltas.
- Computes gross rewards vs net user flows and mints protocol fee shares (treasury/provider) in `stAztec`.
- Updates `exchangeRate` and reporting checkpoints; no AZTEC moves during accounting.

### Safety controls
- SafetyModule enforces deposit caps, rate-drop limits, queue pressure, and accounting liveness; can pause the system.
- GuardianMultisig holds `DEFAULT_ADMIN_ROLE` and `GUARDIAN_ROLE` to pause/unpause and adjust SafetyModule parameters.

## Key invariants
- `exchangeRate = totalAssets() / stAztec.totalSupply()` after each accounting update.
- FIFO withdrawal ordering; locked `assetsExpected` honored at claim time.
- Rebalance never stakes funds needed for pending withdrawals.

## Components (summary)
- **OllaCore**: Vault, accounting, coordination, fee minting, safety enforcement.
- **StAztec**: Non-rebasable ERC20 receipt token; mint/burn gated to OllaCore.
- **StakingManager**: Stakes/unstakes with the single validator, harvests rewards, manages key queue.
- **WithdrawalQueue**: FIFO withdrawal lock/finalize/claim flow.
- **RewardsVault**: Holds validator coinbase rewards; withdrawable to OllaCore.
- **SafetyModule**: Caps, circuit breakers, liveness checks; can pause.
- **GuardianMultisig**: Emergency and admin authority.

## Development plan
Refer to `research/technical/architecture/milestones.md` for the canonical 12-milestone plan for V1 implementation and validation.
