# Certora Formal Verification

## Setup

1. Install Certora CLI:

   ```bash
   pip install certora-cli
   ```

2. Set your Certora API key:

   ```bash
   export CERTORAKEY=<your-key>
   ```

   Free keys for open-source projects: <https://www.certora.com/signup>

3. Ensure `solc` 0.8.27 is available:

   ```bash
   solc-select install 0.8.27
   solc-select use 0.8.27
   ```

## Running Specs

From the `contracts/` directory:

```bash

# OllaCore accounting properties
certoraRun certora/confs/OllaCore.conf

# Exchange rate and conversion properties
certoraRun certora/confs/ExchangeRate.conf

# WithdrawalQueue properties (standalone, no external deps)
certoraRun certora/confs/WithdrawalQueue.conf

# WithdrawalQueue finalization loop (pessimistic unrolling, slower)
certoraRun certora/confs/WithdrawalQueueDeepLoop.conf

# OllaVault deposit/redeem safety, counter monotonicity, role gating
certoraRun certora/confs/OllaVault.conf
```

## Spec Overview

| Spec | Contract | Properties |
|------|----------|------------|
| `WithdrawalQueue.spec` | WithdrawalQueue | FIFO ordering, pointer monotonicity, pending assets consistency, claim-deletes-request |
| `OllaCoreAccounting.spec` | OllaCore | Fee bounds, treasury split bounds, rebalance FSM transitions, report timestamp monotonicity, parameter setter bounds |
| `ExchangeRate.spec` | OllaCore | Conversion round-trip loss, virtual offset protection, rate consistency |
| `OllaVault.spec` | OllaVault | Deposit/redeem value conservation, counter monotonicity, role gating, pause behavior, fee bounds |

## Known Issues

### OllaVault spec: Certora Prover crash on `redeem()` (error 2773053678)

The OllaVault spec run currently **fails** due to a Certora Prover bug (`DanglingAllocatorIdException`) triggered by SafeERC20 low-level calls compiled with `via_ir=true`. The crash occurs during the prover's initial contract transformation phase (BMC unrolling of `redeem`), which aborts the entire run before any rules are checked.

- **Root cause**: SafeERC20's `safeTransfer`/`safeTransferFrom` use inline assembly that, under `via_ir` bytecode, produces pointer analysis failures (error code 1277565207). For most functions these are non-fatal warnings. For `redeem()` -- which combines a loop (`_findClaimableRequest`) with `safeTransfer` (`_claimWithdrawal`) -- the failure escalates to a fatal `DanglingAllocatorIdException` during BMC unrolling.
- **Why `via_ir` is required**: OllaCore.sol hits "stack too deep" without it; `via_ir=true` is set globally in `foundry.toml`.
- **Workarounds attempted**: `solc_optimize: "0"`, NONDET summaries for `transfer`/`transferFrom`, filtering `redeem`/`claimRequestById` from parametric rules. None resolve the crash since it happens before rules execute.
- **Spec status**: The spec and filters are correct. Once Certora fixes SafeERC20 pointer analysis under `via_ir`, the run should pass without changes.

## Harnesses

Harnesses expose internal state for verification without modifying production code.
They inherit from the real contract and add `view` functions that read private storage.
