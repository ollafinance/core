# GuardianMultisig — Emergency Guardian

| Section | Specification |
| --- | --- |
| **Purpose** | Override authority for safety, pausing, parameter adjustment, circuit breaker management. |
| **State Variables (typed)** | `address[] owners`; `uint256 threshold` |
| **Events** | `Paused()`; `Unpaused()`; `DepositCapChanged(uint256)`; `BreakerReset()` |
| **Roles and Permissions** | `DEFAULT_ADMIN_ROLE`, `GUARDIAN_ROLE` |
| **Key Functions (typed and role scoped)** | `function pauseCore()` — guardian; `function unpauseCore()` — guardian; `function adjustCap(uint256)` — guardian or admin; `function setBreakerLimits(...)` — guardian or admin; `function resetBreaker()` — guardian or admin |

