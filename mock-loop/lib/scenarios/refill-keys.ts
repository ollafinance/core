import type { WalletClient, PublicClient } from "viem";
import type { ProviderKeysScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { executeProviderKeys } from "./provider-keys.js";

export async function executeRefillKeys(
  scenario: ProviderKeysScenario,
  _tick: number,
  _clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses,
  runState: any
): Promise<ActionResult> {
  const result = await executeProviderKeys(
    {
      ...scenario,
      minKeys: 1,
      type: "provider-keys",
    },
    _tick,
    _clients,
    addresses,
    runState
  );

  const data = { ...result.data } as Record<string, unknown>;
  if ("minKeys" in data) delete data.minKeys;

  return {
    ...result,
    scenario: "refill-keys",
    data,
  };
}
