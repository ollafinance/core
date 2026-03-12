# Deployment Improvements

This file tracks deployment-readiness issues outside core protocol logic.

## P3 - Etherscan verification config gaps (LOW PRIORITY)

### Problem

`contracts/foundry.toml` contains `[etherscan]` entries for Sepolia and Polygon Mumbai, but not Mainnet.

### Proposed fix

1. Add `mainnet = { key = "${ETHERSCAN_API_KEY}" }` to `[etherscan]`.
2. Confirm docs mention required verification env vars for both Sepolia and Mainnet.

### Acceptance criteria

- `forge script ... --verify --rpc-url mainnet` has complete scanner config.

## P3 - Mainnet deployment front-running risk window (LOW PRIORITY)

### Problem

During public mempool deployment/activation, observers can react to known sequence and timing of governance operations.

### Proposed fix

1. Add operational guidance (docs/runbook):
   - use private tx relay / protected RPC where available
   - stage activation steps tightly (minimal gap between schedule-execute when delay allows)
   - keep protocol paused until wiring and role checks pass
2. Add explicit "activation window" checklist:
   - pre-check state
   - execute sequence
   - post-check state and monitoring hooks

### Acceptance criteria

- Mainnet runbook contains concrete mitigation steps and ordering.
- Operators can execute deployment with reduced mempool exposure.

## P2 - Mainnet multisig proposer deployment flow (MEDIUM PRIORITY)

### Problem

Current deployment flow assumes direct EOA broadcasting. For mainnet operations, we need support for Gnosis Safe multisig execution with a proposer pattern.

### Proposed fix

1. Add deployment/ops support for generating Safe-compatible calldata bundles.
2. Support proposer-submitted transactions for multisig review/approval before execution.
3. Document required mainnet runbook steps for proposer, signers, and final executor.

### Acceptance criteria

- Mainnet deployment path can be executed through a Gnosis Safe multisig using proposer workflow.
- Runbook clearly defines proposer, signer, and execution responsibilities.
