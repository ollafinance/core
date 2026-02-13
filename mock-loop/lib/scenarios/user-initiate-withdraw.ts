import type { WalletClient, PublicClient } from "viem";
import type { UserInitiateWithdrawScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { createUserWallet, getStAztec, getOllaCore } from "../client.js";

export async function executeUserInitiateWithdraw(
  _scenario: UserInitiateWithdrawScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  // Create user wallet from scenario private key
  const userWallet = createUserWallet(clients.publicClient.transport.url, _scenario.privateKey);
  const userAddress = userWallet.account?.address;

  if (!userAddress) {
    return {
      scenario: "user-initiate-withdraw",
      success: false,
      error: "Failed to derive user address from private key",
    };
  }

  try {
    const stAztec = getStAztec(addresses, userWallet);
    const ollaCore = getOllaCore(addresses, userWallet);

    // Get user's full stAztec balance
    const shares = await stAztec.read.balanceOf([userAddress]) as bigint;

    if (shares === 0n) {
      return {
        scenario: "user-initiate-withdraw",
        success: true,
        data: {
          user: userAddress,
          action: "none_needed",
          reason: "No shares to withdraw",
        },
      };
    }

    // Call requestRedeem for full balance
    const txHash = await ollaCore.write.requestRedeem([shares, userAddress]);

    return {
      scenario: "user-initiate-withdraw",
      success: true,
      txHash,
      data: {
        user: userAddress,
        shares: shares.toString(),
      },
    };
  } catch (error) {
    return {
      scenario: "user-initiate-withdraw",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
