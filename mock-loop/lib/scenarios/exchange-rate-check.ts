import type { PublicClient, WalletClient } from "viem";
import type { ExchangeRateCheckScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore } from "../client.js";

export async function executeExchangeRateCheck(
  _scenario: ExchangeRateCheckScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses,
  scenarioState: any
): Promise<ActionResult> {
  try {
    const ollaCore = getOllaCore(addresses, clients.publicClient);
    const currentRate = (await ollaCore.read.exchangeRate()) as bigint;
    const currentRateStr = currentRate.toString();
    const previousRate = scenarioState.lastExchangeRate as string | undefined;

    // Store current rate for next check
    scenarioState.lastExchangeRate = currentRateStr;

    if (!previousRate) {
      return {
        scenario: "exchange-rate-check",
        success: true,
        data: {
          exchangeRate: currentRateStr,
          note: "initial reading",
        },
      };
    }

    const prev = BigInt(previousRate);
    const decreased = currentRate < prev;

    if (decreased) {
      const delta = prev - currentRate;
      return {
        scenario: "exchange-rate-check",
        success: false,
        error: `Exchange rate decreased from ${previousRate} to ${currentRateStr} (delta: -${delta.toString()})`,
        data: {
          previousRate,
          currentRate: currentRateStr,
          delta: `-${delta.toString()}`,
        },
      };
    }

    const delta = currentRate - prev;
    return {
      scenario: "exchange-rate-check",
      success: true,
      data: {
        previousRate,
        currentRate: currentRateStr,
        delta: delta.toString(),
        unchanged: delta === 0n,
      },
    };
  } catch (error) {
    return {
      scenario: "exchange-rate-check",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
