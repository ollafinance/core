import type { WalletClient, PublicClient } from "viem";
import type { ProviderKeysScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getStakingProviderRegistry } from "../client.js";

export async function executeProviderKeys(
  scenario: ProviderKeysScenario,
  _tick: number,
  _clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses,
  runState: any
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

    const seedBase =
      (BigInt(Date.now()) << 32n) |
      BigInt(Math.floor(Math.random() * 0x100000000));
    for (let i = 0; i < keysToAdd; i++) {
      // Generate deterministic dummy attester addresses and keys
      const seed = seedBase + BigInt(i);
      keyStores.push({
        attester: `0x${seed.toString(16).padStart(40, "0")}` as `0x${string}`,
        publicKeyG1: {
          x: seed,
          y: seed + 1n,
        },
        publicKeyG2: {
          x0: seed + 2n,
          x1: seed + 3n,
          y0: seed + 4n,
          y1: seed + 5n,
        },
        proofOfPossession: {
          x: seed + 6n,
          y: seed + 7n,
        },
      });
    }

    // Add keys to provider
    const txHash = await registry.write.addKeysToProvider([keyStores]);
    if (!runState.attesters) {
      runState.attesters = [];
    }
    for (const keyStore of keyStores) {
      runState.attesters.push(keyStore.attester);
    }

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
