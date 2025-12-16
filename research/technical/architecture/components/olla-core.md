# OllaCore — Core Staking Contract

| Section | Specification |
| --- | --- |
| **Purpose** | Main vault (ERC7540) for deposits and withdrawals, staking flows, accounting and fee minting, system state control via safety. |
| **State Variables (typed)** | `address stAztec`; `address stakingManager`; `address withdrawalQueue`; `address rewardsVault`; `address safetyModule`; `address aztecRollup`; `uint256 totalBufferedAssets`; `uint256 exchangeRate`; `uint256 lastTotalAssets`; `uint256 cumulativeDeposits`; `uint256 cumulativeWithdrawals`; `uint256 lastReportDeposits`; `uint256 lastReportWithdrawals` |
| **Events** | `Deposit(address,address,uint256,uint256)`; `WithdrawalRequested(address,uint256,uint256,uint256,uint256)`; `WithdrawalFinalized(uint256,uint256)`; `WithdrawalClaimed(uint256,address,uint256)`; `RewardsHarvested(uint256)`; `AccountingUpdated(uint256,uint256,uint256,uint256)`; `ValidatorStateRead(uint256,uint256,uint256)`; `Rebalanced(uint256,uint256,uint256,uint256)`; `Paused()`; `Unpaused()` |
| **Roles and Permissions** | `DEFAULT_ADMIN_ROLE`, `GUARDIAN_ROLE`, `OPERATOR_ROLE`, `CORE_ROLE` |
| **Key Functions (typed and role scoped)** | `function deposit(uint256 assets,address receiver)` — public; `function requestWithdrawal(uint256 shares,address receiver)` — public; `function rebalance()` — only `OPERATOR_ROLE`; `function updateAccounting()` — only `OPERATOR_ROLE`; `function finalizeWithdrawals(uint256 available)` — only `OPERATOR_ROLE`; `function totalAssets() view returns(uint256)` — view; `function pause()` — only `GUARDIAN_ROLE`; `function unpause()` — only `GUARDIAN_ROLE` |

