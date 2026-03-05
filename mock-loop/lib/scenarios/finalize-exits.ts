import type { PublicClient, WalletClient } from "viem";
import type { FinalizeExitsScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getStakingManager, createUserWallet } from "../client.js";

export async function executeFinalizeExits(
  scenario: FinalizeExitsScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  try {
    const wallet = scenario.privateKey
      ? createUserWallet(clients.publicClient.transport.url, scenario.privateKey)
      : clients.operatorWallet;

    const stakingManager = getStakingManager(addresses, wallet);
    const stakingManagerRead = getStakingManager(addresses, clients.publicClient);

    const exitCountBefore = await stakingManagerRead.read.getPendingUnstakeCount() as bigint;
    // Use explicit gas limit to avoid gas estimation undercount.
    // StakingManager._refreshSingleAttester calls rollup.finalizeWithdraw which
    // may have complex gas requirements.
    const txHash = await stakingManager.write.refreshAttesterState([[]], { gas: 1_000_000n });
    const receipt = await clients.publicClient.waitForTransactionReceipt({ hash: txHash });
    const exitCountAfter = await stakingManagerRead.read.getPendingUnstakeCount() as bigint;

    return {
      scenario: "finalize-exits",
      success: receipt.status === "success",
      txHash,
      data: {
        caller: wallet.account?.address,
        permissionless: !!scenario.privateKey,
        exitCountBefore: exitCountBefore.toString(),
        exitCountAfter: exitCountAfter.toString(),
        exitsFinalized: (exitCountBefore - exitCountAfter).toString(),
      },
    };
  } catch (error) {
    return {
      scenario: "finalize-exits",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
