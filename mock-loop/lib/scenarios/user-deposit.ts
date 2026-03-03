import type { WalletClient, PublicClient } from "viem";
import type { UserDepositScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { createUserWallet, getAsset, getOllaVault } from "../client.js";

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

    // Step 1: Approve OllaVault to spend user's assets
    const asset = getAsset(addresses, userWallet);
    const ollaVault = getOllaVault(addresses, userWallet);
    const approveTx = await asset.write.approve([addresses.OllaVaultProxy, amount]);

    // Step 2: Deposit via OllaVault
    const depositTx = await ollaVault.write.deposit([amount, userAddress, 0n], { gas: 500_000n });

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
