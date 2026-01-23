# WithdrawalQueue — FIFO Withdrawal System

| Section | Specification |
| --- | --- |
| **Purpose** | Locks withdrawals at request `exchangeRate` and completes sequentially with available liquidity. |
| **State Variables (typed)** | `address core`; `uint256 nextRequestId`; `uint256 nextPendingId`; `mapping(uint256=>WithdrawalRequest) requests`; `uint256 totalPendingAssets` |
| **Events** | `WithdrawalRequested(uint256,address,uint256,uint256,uint256)`; `WithdrawalFinalized(uint256,uint256)`; `WithdrawalClaimed(uint256,address,uint256)` |
| **Roles and Permissions** | `CORE_ROLE`, `DEFAULT_ADMIN_ROLE` |
| **Key Functions (typed and role scoped)** | `function requestWithdrawal(address user,uint256 shares,uint256 assets,uint256 rate) returns(uint256)` — only `CORE_ROLE`; `function finalizeWithdrawals(uint256 available) returns(uint256)` — only `CORE_ROLE`; `function claimWithdrawal(uint256 id) returns(uint256)` — public; `function getRequest(uint256 id) view returns(WithdrawalRequest)` — view; `function nextUnfinalized() view returns(uint256)` — view; `function previewFinalizeWithdrawals(uint256 available) view returns(uint256)` — view |
