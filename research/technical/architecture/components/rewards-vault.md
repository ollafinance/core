# RewardsVault — Rewards and Fee Management

| Section | Specification |
| --- | --- |
| **Purpose** | Custodies AZTEC rewards/fees sent from the Aztec rollup (via `claimSequencerRewards`) and allows `OllaCore` to withdraw them; supports a configurable `treasury` address for future fee routing. |
| **State Variables (typed)** | `IERC20 rewardsToken`; `address core`; `address treasury` |
| **Events** | `FundsReceived(uint256 amount)`; `RewardsWithdrawn(uint256 amount)`; `TreasuryUpdated(address oldTreasury,address newTreasury)` |
| **Roles and Permissions** | `CORE_ROLE` (withdraw to core); `DEFAULT_ADMIN_ROLE` (set treasury) |
| **Key Functions (typed and role scoped)** | `postReceiveFundsHook(uint256 amount)` — callable by `StakingManager` (and potentially `AztecRollup`) after funds are transferred; `withdrawToCore(uint256 amount)` — only `CORE_ROLE`; `setTreasury(address newTreasury)` — only `DEFAULT_ADMIN_ROLE`; `getAvailableFunds() view returns(uint256)`; `treasury() view returns(address)`; `core() view returns(address)`; `rewardsToken() view returns(IERC20)` |
