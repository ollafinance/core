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

    const totalStaked = await rollupRead.read.totalStaked() as bigint;
    const stakedAmount = totalStaked;
    const rateBps = BigInt(scenario.rateBps);
    const perTickReward = (stakedAmount * rateBps) / 10_000n;
    const targetRate = perTickReward;

    if (state?.lastRate !== targetRate.toString()) {
      const rateTx = await rollup.write.setRewardRatePerSecond([targetRate]);
      actions.push(`setRewardRatePerSecond: ${rateTx}`);
      state.lastRate = targetRate.toString();
    }

    // Each tick: call tick() on the rollup
    const tickTx = await rollup.write.tick([addresses.RewardsCollectorProxy]);
    actions.push(`tick: ${tickTx}`);

    return {
      scenario: "mock-rewards",
      success: true,
      data: {
        actions,
        rateBps: scenario.rateBps,
        rollupTotalStaked: totalStaked.toString(),
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
