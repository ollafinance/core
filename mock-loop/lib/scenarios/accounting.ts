import type { WalletClient, PublicClient } from "viem";
import type { AccountingScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore, createUserWallet, loadAbi } from "../client.js";
import { findAllAttesters } from "./attesters.js";

export async function executeAccounting(
  _scenario: AccountingScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  // Use non-operator wallet when privateKey is provided (permissionless mode)
  const callerWallet = _scenario.privateKey
    ? createUserWallet(clients.publicClient.transport.url, _scenario.privateKey)
    : clients.operatorWallet;

  const ollaCore = getOllaCore(addresses, callerWallet);

  try {
    const stakingManagerAbi = loadAbi("StakingManager");
    const stakingManagerAddress = addresses.StakingManagerProxy as `0x${string}`;
    const allAttesters = await findAllAttesters(clients.publicClient, stakingManagerAddress);
    await callerWallet.writeContract({
      address: stakingManagerAddress,
      abi: stakingManagerAbi,
      functionName: "refreshAttesterState",
      args: [allAttesters],
      chain: null,
      account: callerWallet.account,
    } as any);
    const txHash = await ollaCore.write.updateAccounting([]);

    return {
      scenario: "accounting",
      success: true,
      txHash,
      data: {
        caller: callerWallet.account?.address,
        permissionless: !!_scenario.privateKey,
      },
    };
  } catch (error) {
    return {
      scenario: "accounting",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
