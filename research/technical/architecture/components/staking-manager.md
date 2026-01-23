# StakingManager — Staking Delegation and Keys

| Section | Specification |
| --- | --- |
| **Purpose** | Stakes with validator, initiates unstake, harvests rewards, manages keys. |
| **State Variables (typed)** | `address core`; `address rewardsVault`; `ProviderConfig provider`; `Queue providerQueue`; `address[] activatedAttesters`; `address[] pendingUnstakeRequests` |
| **Events** | `ProviderSet(address,address)`; `KeysAddedToProvider(address[])`; `StakedWithProvider(address,uint256)`; `UnstakeInitiated(address,uint256)`; `UnstakeFinalized(address,uint256)`; `UnstakedFundsClaimed(uint256)`; `QueueDripped(address)` |
| **Roles and Permissions** | `CORE_ROLE`, `STAKING_PROVIDER_ADMIN_ROLE`, `DEFAULT_ADMIN_ROLE` |
| **Key Functions (typed and role scoped)** | `function stake(uint256 amount)` — only `CORE_ROLE`; `function unstake(uint256 amount)` — only `CORE_ROLE`; `function cleanActivatedAttesters()` — only `CORE_ROLE`; `function getUnstakedFunds() returns(uint256)` — only `CORE_ROLE`; `function harvestRewards() returns(uint256)` — only `CORE_ROLE`; `function addKeysToProvider(KeyStore[] ks)` — only `STAKING_PROVIDER_ADMIN_ROLE`; `function dripQueue(uint256 count)` — only `STAKING_PROVIDER_ADMIN_ROLE`; `function setProviderRewardsRecipient(address rewardsRecipient)` — only `STAKING_PROVIDER_ADMIN_ROLE`; `function getStakingState() view returns(StakingState)`; `function getQueueLength() view returns(uint256)`; `function getProviderConfig() view returns(ProviderConfig)`; `function getActivatedAttesterCount() view returns(uint256)`; `function getPendingUnstakeCount() view returns(uint256)`; `function isUnstakePending(address attester) view returns(bool)` |
