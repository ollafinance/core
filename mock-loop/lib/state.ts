import type { PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type {
  DeploymentAddresses,
  TickState,
  UserState,
  ScenarioConfig,
} from "./types.js";
import {
  getOllaCore,
  getStakingManager,
  getWithdrawalQueue,
  getAsset,
  getStAztec,
  getStakingProviderRegistry,
} from "./client.js";

// Helper to convert BigInt to string
const toString = (n: bigint): string => n.toString();

export async function readFullState(
  publicClient: PublicClient,
  addresses: DeploymentAddresses,
  scenarios: ScenarioConfig[],
  tick: number
): Promise<TickState> {
  const timestamp = Date.now().toString();

  // Get contract instances
  const ollaCore = getOllaCore(addresses, publicClient);
  const stakingManager = getStakingManager(addresses, publicClient);
  const withdrawalQueue = getWithdrawalQueue(addresses, publicClient);
  const asset = getAsset(addresses, publicClient);
  const stAztec = getStAztec(addresses, publicClient);
  const providerRegistry = getStakingProviderRegistry(addresses, publicClient);

  // Read OllaCore state
  const [totalAssets, exchangeRate, accountingState] = await Promise.all([
    ollaCore.read.totalAssets(),
    ollaCore.read.exchangeRate(),
    ollaCore.read.accountingState(),
  ] as const) as [
    bigint,
    bigint,
    {
      bufferedAssets: bigint;
      stakedPrincipal: bigint;
      rewardsVaultBalance: bigint;
      claimableRewards: bigint;
      rewardsDelta: bigint;
      slashingDelta: bigint;
      cumulativeRewards: bigint;
    },
  ];

  // Read StakingManager state
  const [stakedAmount, pendingUnstakeCount] = await Promise.all([
    stakingManager.read.totalStaked(),
    stakingManager.read.getPendingUnstakeCount(),
  ] as const) as [bigint, bigint];

  // Read WithdrawalQueue state
  const [totalPendingAssets, nextRequestId] = await Promise.all([
    withdrawalQueue.read.totalPendingAssets(),
    withdrawalQueue.read.nextRequestId(),
  ] as const) as [bigint, bigint];

  // Read token balances
  const [coreBalance, stakingManagerBalance, rewardsVaultBalance] =
    await Promise.all([
      asset.read.balanceOf([addresses.OllaCoreProxy]),
      asset.read.balanceOf([addresses.StakingManagerProxy]),
      asset.read.balanceOf([addresses.RewardsVaultProxy]),
    ] as const) as [bigint, bigint, bigint];

  // Read provider registry state
  const availableKeyCount = await providerRegistry.read.getQueueLength() as bigint;

  // Read user states (from user scenarios)
  const userStates: UserState[] = [];
  const userScenarios = scenarios.filter(
    (s): s is Extract<ScenarioConfig, { privateKey: string }> =>
      "privateKey" in s
  );

  for (const scenario of userScenarios) {
    // Derive address from private key by creating a wallet client
    const account = privateKeyToAccount(scenario.privateKey as `0x${string}`);
    const userAddress = account.address;

    const [assetBalance, stAztecBalance, activeRequestIds] =
      await Promise.all([
        asset.read.balanceOf([userAddress]),
        stAztec.read.balanceOf([userAddress]),
        ollaCore.read.activeRequestIds([userAddress]),
      ] as const) as [bigint, bigint, bigint[]];

    userStates.push({
      address: userAddress,
      assetBalance: toString(assetBalance),
      stAztecBalance: toString(stAztecBalance),
      activeRequestIds: activeRequestIds.map(toString),
    });
  }

  // Deduplicate users (same user might appear in multiple scenarios)
  const uniqueUsers = userStates.filter(
    (user, index, self) =>
      index === self.findIndex((u) => u.address === user.address)
  );

  return {
    tick,
    timestamp,
    ollaCore: {
      totalAssets: toString(totalAssets),
      exchangeRate: toString(exchangeRate),
      accountingState: {
        bufferedAssets: toString(accountingState.bufferedAssets),
        stakedPrincipal: toString(accountingState.stakedPrincipal),
        rewardsVaultBalance: toString(accountingState.rewardsVaultBalance),
        claimableRewards: toString(accountingState.claimableRewards),
        rewardsDelta: toString(accountingState.rewardsDelta),
        slashingDelta: toString(accountingState.slashingDelta),
        cumulativeRewards: toString(accountingState.cumulativeRewards),
      },
    },
    stakingManager: {
      stakedAmount: toString(stakedAmount),
      pendingUnstakeCount: toString(pendingUnstakeCount),
    },
    withdrawalQueue: {
      totalPendingAssets: toString(totalPendingAssets),
      nextRequestId: toString(nextRequestId),
    },
    balances: {
      core: toString(coreBalance),
      stakingManager: toString(stakingManagerBalance),
      rollup: "0", // Placeholder - would need rollup contract
      rewardsVault: toString(rewardsVaultBalance),
    },
    users: uniqueUsers,
    providerRegistry: {
      availableKeyCount: toString(availableKeyCount),
    },
  };
}
