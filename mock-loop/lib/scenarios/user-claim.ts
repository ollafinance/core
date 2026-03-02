import type { WalletClient, PublicClient } from "viem";
import type { UserClaimScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { createUserWallet, getOllaVault } from "../client.js";

export async function executeUserClaim(
  _scenario: UserClaimScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  // Create user wallet from scenario private key
  const userWallet = createUserWallet(clients.publicClient.transport.url, _scenario.privateKey);
  const userAddress = userWallet.account?.address;

  if (!userAddress) {
    return {
      scenario: "user-claim",
      success: false,
      error: "Failed to derive user address from private key",
    };
  }

  try {
    const ollaVault = getOllaVault(addresses, clients.publicClient);
    const userOllaVault = getOllaVault(addresses, userWallet);

    // Get user's active request IDs
    const activeRequestIds = await ollaVault.read.activeRequestIds([userAddress]) as bigint[];

    // Filter to only finalized requests (we'd need to check each request status)
    // For now, we'll attempt to claim all active requests
    const claimedRequests: string[] = [];
    const failedRequests: { id: string; error: string }[] = [];

    for (const requestId of activeRequestIds) {
      try {
        const txHash = await userOllaVault.write.claimRequestById([requestId]);
        claimedRequests.push(`${requestId.toString()}:${txHash}`);
      } catch (error) {
        // Request may not be finalized yet
        failedRequests.push({
          id: requestId.toString(),
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    return {
      scenario: "user-claim",
      success: claimedRequests.length > 0 || activeRequestIds.length === 0,
      data: {
        user: userAddress,
        activeRequests: activeRequestIds.length,
        claimed: claimedRequests.length,
        failed: failedRequests.length,
        claimedRequests,
        failedRequests: failedRequests.map((f) => f.id),
      },
    };
  } catch (error) {
    return {
      scenario: "user-claim",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
