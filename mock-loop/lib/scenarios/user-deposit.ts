import type { WalletClient, PublicClient } from "viem";
import type { UserDepositScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { createUserWallet, getAsset, getOllaCore } from "../client.js";
import { parseEther } from "viem";

export async function executeUserDeposit(
  scenario: UserDepositScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  // Create user wallet from scenario private key
  const userWallet = createUserWallet(clients.publicClient.transport.url, scenario.privateKey);
  const userAddress = userWallet.account?.address;

  if (!userAddress) {
    return {
      scenario: "user-deposit",
      success: false,
      error: "Failed to derive user address from private key",
    };
  }

  try {
    // Step 0: Mint tokens to user (using operator wallet)
    const assetOperator = getAsset(addresses, clients.operatorWallet);
    const amount = BigInt(scenario.amount);
    const mintTx = await assetOperator.write.mint([userAddress, amount]);

    // Step 1: Approve OllaCore to spend user's assets
    const asset = getAsset(addresses, userWallet);
    const ollaCore = getOllaCore(addresses, userWallet);
    const approveTx = await asset.write.approve([addresses.OllaCoreProxy, amount]);

    // Step 2: Deposit
    const depositTx = await ollaCore.write.deposit([amount, userAddress]);

    return {
      scenario: "user-deposit",
      success: true,
      data: {
        user: userAddress,
        amount: scenario.amount,
        mintTx,
        approveTx,
        depositTx,
      },
    };
  } catch (error) {
    return {
      scenario: "user-deposit",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
