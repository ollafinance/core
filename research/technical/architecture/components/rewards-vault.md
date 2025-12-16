# RewardsVault — Rewards and Fee Management

| Section | Specification |
| --- | --- |
| **Purpose** | Receives validator coinbase rewards and exposes balance to core. |
| **State Variables (typed)** | `address core`; `address treasury`; `uint256 totalRewards` |
| **Events** | `RewardsReceived(uint256)`; `RewardsWithdrawn(uint256)` |
| **Roles and Permissions** | `CORE_ROLE`, `DEFAULT_ADMIN_ROLE` |
| **Key Functions (typed and role scoped)** | `function receiveRewards(uint256 amount)` — callable by StakingManager or AztecRollup; `function withdrawToCore(uint256 amount)` — only `CORE_ROLE`; `function balance() view returns(uint256)` — view; `function setTreasury(address t)` — only `DEFAULT_ADMIN_ROLE` |

