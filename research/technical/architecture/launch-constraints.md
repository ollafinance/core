# V1 Launch Constraints

## Operational constraints

| Parameter | V1 Value | Rationale |
| --- | --- | --- |
| Staking Provider Count | 1 (single trusted staking provider) | Simplify operations, reduce complexity |
| Initial Deposit Cap | $100,000 | Limit risk during early testing |
| Maximum Deposit Cap | $500,000 | Conservative growth ceiling for V1 |
| Initial Withdrawal Cap | $50,000 | Limit risk during early testing |
| Maximum Withdrawal Cap | $250,000 | Conservative growth ceiling for V1 |
| Protocol Fee | 10% (1,000 bps) | Simple fee structure |
| Treasury/operator split | 50% / 50% of fee shares | Simple fee split |
| Oracle Operator | Single trusted `OPERATOR_ROLE` address | Eliminate consensus complexity |
| Guardian Powers | Active indefinitely | Manual oversight during early phase |
| Withdrawal Method | FIFO queue (non-transferable) | Simplest robust implementation |
| Circuit Breaker - Rate Drop | 5% max per update | Detect anomalies |
| Circuit Breaker - Queue Ratio | 30% of TVL max | Prevent bank-run dynamics |

## Technical scope (V1 does NOT support)

- Multiple validators or providers.
- Dynamic validator allocation or routing.
- Transferable withdrawal positions.
- Multi-oracle consensus (no oracle contract at all).
- Automated guardian sunset or DAO governance.
- Complex fee distribution or multi-level commissions.

## Security guardrails

1. Guardian Multisig: 3-of-5 trusted signers with instant pause capability.
2. Deposit Caps: Hard TVL cap via SafetyModule.
3. Circuit Breakers: Automatic pause on large rate drops, high queue pressure, or accounting liveness failure.
4. On-chain Sanity Checks: OllaCore and SafetyModule bound rewards or slashing deltas returned by AztecRollup.
5. Single Validator: Reduced attack surface and simpler monitoring for V1.
6. Role-Based Access: OpenZeppelin AccessControl for all privileged functions.

