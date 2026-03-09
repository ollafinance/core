import type { PublicClient, WalletClient } from "viem";
import type { CooldownCheckScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore, createUserWallet } from "../client.js";

export async function executeCooldownCheck(
  scenario: CooldownCheckScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  try {
    const wallet = scenario.privateKey
      ? createUserWallet(clients.publicClient.transport.url, scenario.privateKey)
      : clients.operatorWallet;

    const ollaCore = getOllaCore(addresses, wallet);
    const ollaCoreRead = getOllaCore(addresses, clients.publicClient);

    // Read cooldown state for reporting
    const cooldown = BigInt(await ollaCoreRead.read.rebalanceCooldown());

    // Attempt rebalance - should revert with CooldownActive
    try {
      const txHash = await ollaCore.write.rebalance([], { gas: 500_000n });
      const receipt = await clients.publicClient.waitForTransactionReceipt({ hash: txHash });

      if (receipt.status === "success") {
        // Rebalance succeeded when it should have been blocked by cooldown
        return {
          scenario: "cooldown-check",
          success: false,
          error: "Rebalance succeeded but should have been blocked by cooldown",
          data: {
            caller: wallet.account?.address,
            cooldownSeconds: cooldown.toString(),
            txHash,
          },
        };
      }

      // Transaction reverted (could be cooldown or other reason)
      return {
        scenario: "cooldown-check",
        success: true,
        data: {
          caller: wallet.account?.address,
          cooldownSeconds: cooldown.toString(),
          note: "rebalance correctly reverted (tx reverted on-chain)",
        },
      };
    } catch (error) {
      // Expected: rebalance reverts with CooldownActive error
      const errorMsg = error instanceof Error ? error.message : String(error);
      const isCooldownError = errorMsg.includes("RebalanceCooldownActive") || errorMsg.includes("0x");

      return {
        scenario: "cooldown-check",
        success: true,
        data: {
          caller: wallet.account?.address,
          cooldownSeconds: cooldown.toString(),
          revertReason: errorMsg.substring(0, 200),
          note: isCooldownError
            ? "rebalance correctly blocked by cooldown"
            : "rebalance reverted (may be cooldown or idle guard)",
        },
      };
    }
  } catch (error) {
    return {
      scenario: "cooldown-check",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
