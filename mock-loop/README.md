# Mock Loop v2

TypeScript-based mock loop for automated protocol testing on local Anvil.

## Overview

The mock loop simulates protocol operations by running configurable scenarios at regular intervals. It provides full control over output, state inspection, and scenario scheduling.

## Quick Start

```bash
# Start Anvil chain (keep running)
yarn dev:chain

# Deploy contracts and run mock loop
yarn deploy:local --quiet && yarn dev:mock-loop:until-error
```

## Commands

- `yarn dev:mock-loop` - Run continuous loop (5s intervals)
- `yarn dev:mock-loop:once` - Run single tick and exit
- `yarn dev:mock-loop:until-error` - Run until any scenario fails
- `yarn dev:mock-loop -- --once --until-error` - Combine flags

## Configuration

Edit `config.ts` to customize scenarios:

- **provider-keys**: Maintains minimum attester keys in registry
- **mock-rewards**: Sets reward rate and accrues rewards
- **user-deposit**: Mints and deposits tokens for test user
- **rebalance**: Runs operator rebalance state machine
- **accounting**: Updates protocol accounting
- **user-initiate-withdraw**: Requests redemption of user shares
- **user-claim**: Claims finalized withdrawals

Each scenario supports:

- `enabled: boolean` - Enable/disable
- `every?: number` - Run every N ticks
- `at?: number` - Run at specific tick
- `privateKey?: string` - For user scenarios

## Output

Each run creates a timestamped directory in `mock-loop/runs/<timestamp>/`:

- `init.json` - Config and contract addresses
- `tick-NNN.json` - Full state snapshot per tick
- `log.txt` - Human-readable execution log

## Console Output Format

```
Tick 001 | actions: ✓✓✓.... | 64ms | ✓
  bufferedAssets: 200k |stakedPrincipal: 0 |rewardsVaultBalance: 0 ...
```

Actions pattern:

- `✓` = executed successfully
- `.` = skipped (schedule didn't match)
- `d` = disabled
- `⚠️` = error occurred

Values shown in ether format with M (millions), k (thousands), or normal units.

## Architecture

- `index.ts` - Main loop orchestration
- `config.ts` - Default scenario configuration
- `lib/client.ts` - Viem clients and contract instances
- `lib/state.ts` - Protocol state reader
- `lib/logger.ts` - Console and file logging
- `lib/output.ts` - Run directory management
- `lib/scenarios/` - Individual scenario implementations
