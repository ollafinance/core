import type { WalletClient, PublicClient } from "viem";
import type { ProviderKeysScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getStakingProviderRegistry } from "../client.js";

export async function executeProviderKeys(
  scenario: ProviderKeysScenario,
  _tick: number,
  _clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  const registry = getStakingProviderRegistry(addresses, _clients.operatorWallet);

  try {
    // Check available keys
    const availableKeyCount = await registry.read.getQueueLength() as bigint;

    if (availableKeyCount >= BigInt(scenario.minKeys)) {
      return {
        scenario: "provider-keys",
        success: true,
        data: {
          action: "none_needed",
          availableKeys: availableKeyCount.toString(),
          minKeys: scenario.minKeys,
        },
      };
    }

    // Need to add keys - generate dummy keys
    const keysToAdd = scenario.seedCount;
    const keyStores = [];

    for (let i = 0; i < keysToAdd; i++) {
      // Generate deterministic dummy attester addresses and keys
      const seed = Date.now() + i;
      keyStores.push({
        attester: `0x${seed.toString(16).padStart(40, "0")}` as `0x${string}`,
        publicKeyG1: {
          x: BigInt(seed),
          y: BigInt(seed + 1),
        },
        publicKeyG2: {
          x0: BigInt(seed + 2),
          x1: BigInt(seed + 3),
          y0: BigInt(seed + 4),
          y1: BigInt(seed + 5),
        },
        proofOfPossession: {
          x: BigInt(seed + 6),
          y: BigInt(seed + 7),
        },
      });
    }

    // Add keys to provider
    const txHash = await registry.write.addKeysToProvider([keyStores]);

    return {
      scenario: "provider-keys",
      success: true,
      txHash,
      data: {
        action: "add_keys",
        keysAdded: keysToAdd,
        previousCount: availableKeyCount.toString(),
      },
    };
  } catch (error) {
    return {
      scenario: "provider-keys",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
