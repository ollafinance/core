# SafetyModule — Deposit Caps and Circuit Breakers

| Section | Specification |
| --- | --- |
| **Purpose** | TVL caps, rate-drop anomaly detection, queue pressure limits, accounting liveness fail-safe. |
| **State Variables (typed)** | `uint256 depositCap`; `bool paused`; `uint256 minRateDropBps`; `uint256 maxQueueRatioBps`; `uint256 maxAccountingDelay`; `uint256 lastAccountingTimestamp` |
| **Events** | `Paused()`; `Unpaused()`; `DepositCapUpdated(uint256)`; `CircuitBreakerTriggered(bytes32)`; `RateDropLimitUpdated(uint256)`; `QueueRatioLimitUpdated(uint256)` |
| **Roles and Permissions** | `GUARDIAN_ROLE`, `CORE_ROLE`, `DEFAULT_ADMIN_ROLE` |
| **Key Functions (typed and role scoped)** | `function checkDepositAllowed(uint256 deposit,uint256 total) view returns(bool)` — used by Core; `function checkRateDrop(uint256 old,uint256 next)` — Core-triggered; `function checkQueueRatio(uint256 queue,uint256 total)` — Core-triggered; `function checkAccountingLiveness()` — Core or automation; `function setDepositCap(uint256)` — only `DEFAULT_ADMIN_ROLE`; `function pause()` — only `GUARDIAN_ROLE`; `function unpause()` — only `GUARDIAN_ROLE` |

