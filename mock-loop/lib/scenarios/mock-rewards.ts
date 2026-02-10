import type { WalletClient, PublicClient } from "viem";
import type { MockRewardsScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getMockAztecRollup, getRewardsVault } from "../client.js";

// Track if we've initialized the reward rate
let initialized = false;

export async function executeMockRewards(
  scenario: MockRewardsScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  const rollup = getMockAztecRollup(addresses, clients.operatorWallet);
  const rewardsVault = getRewardsVault(addresses, clients.publicClient);

  try {
    const actions: string[] = [];

    // First run: set reward rate
    if (!initialized) {
      const rateTx = await rollup.write.setRewardRatePerSecond([BigInt(scenario.rate)]);
      actions.push(`setRewardRatePerSecond: ${rateTx}`);
      initialized = true;
    }

    // Each tick: call tick() on the rollup
    const tickTx = await rollup.write.tick([addresses.RewardsVaultProxy]);
    actions.push(`tick: ${tickTx}`);

    return {
      scenario: "mock-rewards",
      success: true,
      data: {
        actions,
        rate: scenario.rate,
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
