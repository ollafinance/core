# StakingManager — Staking Delegation and Keys

| Section | Specification |
| --- | --- |
| **Purpose** | Stakes with validator, initiates unstake, harvests rewards, manages keys. |
| **State Variables (typed)** | `address core`; `address rewardsVault`; `ProviderConfig provider`; `KeyStore[] providerQueue`; `uint256 pendingUnstakes`; `uint256 totalStakedPrincipal` |
| **Events** | `ProviderSet(address)`; `KeysAddedToProvider(address[])`; `StakedWithProvider(address,uint256,address)`; `UnstakeInitiated(uint256)`; `UnstakedFundsClaimed(uint256)` |
| **Roles and Permissions** | `CORE_ROLE`, `STAKING_PROVIDER_ADMIN_ROLE`, `DEFAULT_ADMIN_ROLE` |
| **Key Functions (typed and role scoped)** | `function stake(uint256 amount)` — only `CORE_ROLE`; `function unStake(uint256 amount)` — only `CORE_ROLE`; `function getUnstakedFunds() returns(uint256)` — only `CORE_ROLE`; `function harvestRewards() returns(uint256)` — only `CORE_ROLE`; `function addKeysToProvider(KeyStore[] ks)` — only `STAKING_PROVIDER_ADMIN_ROLE`; `function dripQueue(uint256 count)` — only `STAKING_PROVIDER_ADMIN_ROLE`; `function totalStaked() view returns(uint256)`; queue accessors — view |

