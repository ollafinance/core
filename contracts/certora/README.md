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
   Free keys for open-source projects: https://www.certora.com/signup

3. Ensure `solc` 0.8.27 is available:
   ```bash
   solc-select install 0.8.27
   solc-select use 0.8.27
   ```

## Running Specs

From the `contracts/` directory:

```bash
# WithdrawalQueue properties (standalone, no external deps)
certoraRun certora/confs/WithdrawalQueue.conf

# OllaCore accounting properties
certoraRun certora/confs/OllaCore.conf

# Exchange rate and conversion properties
certoraRun certora/confs/ExchangeRate.conf
```

## Spec Overview

| Spec | Contract | Properties |
|------|----------|------------|
| `WithdrawalQueue.spec` | WithdrawalQueue | FIFO ordering, pointer monotonicity, pending assets consistency, claim-deletes-request |
| `OllaCoreAccounting.spec` | OllaCore | Total assets = sum of buckets, flow counter monotonicity, rebalance state machine transitions |
| `ExchangeRate.spec` | OllaCore | Conversion round-trip loss, virtual offset protection, rate consistency |

## Harnesses

Harnesses expose internal state for verification without modifying production code.
They inherit from the real contract and add `view` functions that read private storage.
