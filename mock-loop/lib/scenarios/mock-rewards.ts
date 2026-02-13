import type { WalletClient, PublicClient } from "viem";
import type { MockRewardsScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getMockAztecRollup } from "../client.js";

export async function executeMockRewards(
  scenario: MockRewardsScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses,
  state: any,
  runState: any
): Promise<ActionResult> {
  const rollup = getMockAztecRollup(addresses, clients.operatorWallet);
  const rollupRead = getMockAztecRollup(addresses, clients.publicClient);
  try {
    const actions: string[] = [];

    const attesters = Array.isArray(runState.attesters) ? runState.attesters : [];
    const stakeReads = await Promise.all(
      attesters.map((attester: `0x${string}`) => rollupRead.read.stakes([attester]))
    ) as bigint[];
    const stakedAmount = stakeReads.reduce((sum, stake) => sum + stake, 0n);
    const rateBps = BigInt(scenario.rateBps);
    const perTickReward = (stakedAmount * rateBps) / 10_000n;
    const targetRate = perTickReward * 1000n;

    if (state?.lastRate !== targetRate.toString()) {
      const rateTx = await rollup.write.setRewardRatePerSecond([targetRate]);
      actions.push(`setRewardRatePerSecond: ${rateTx}`);
      state.lastRate = targetRate.toString();
    }

    // Each tick: call tick() on the rollup
    const tickTx = await rollup.write.tick([addresses.RewardsVaultProxy]);
    actions.push(`tick: ${tickTx}`);

    return {
      scenario: "mock-rewards",
      success: true,
      data: {
        actions,
        rateBps: scenario.rateBps,
        stakedAmount: stakedAmount.toString(),
        perTickReward: perTickReward.toString(),
      },
    };
  } catch (error) {
    return {
      scenario: "mock-rewards",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
