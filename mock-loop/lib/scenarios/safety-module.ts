import type { WalletClient, PublicClient } from "viem";
import type { SafetyModuleScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore, getSafetyModule, getMockAztecRollup } from "../client.js";

export async function executeSafetyModule(
  scenario: SafetyModuleScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses,
  scenarioState: any,
  _runState: any
): Promise<ActionResult> {
  const ollaCoreRead = getOllaCore(addresses, clients.publicClient);
  const safetyModuleRead = getSafetyModule(addresses, clients.publicClient);

  try {
    switch (scenario.action) {
      case "configure": {
        // Check if safety module is already set
        const currentModule = await ollaCoreRead.read.safetyModule() as `0x${string}`;
        if (currentModule.toLowerCase() === addresses.SafetyModule.toLowerCase()) {
          return {
            scenario: "safety-module",
            success: true,
            data: {
              action: "configure",
              result: "already_configured",
              safetyModule: currentModule,
            },
          };
        }

        // Set safety module on OllaCore (requires admin role)
        const ollaCore = getOllaCore(addresses, clients.operatorWallet);
        const tx = await ollaCore.write.setSafetyModule([addresses.SafetyModule]);

        scenarioState.configured = true;

        return {
          scenario: "safety-module",
          success: true,
          txHash: tx,
          data: {
            action: "configure",
            result: "configured",
            safetyModule: addresses.SafetyModule,
            previousModule: currentModule,
          },
        };
      }

      case "read-state": {
        // Check if it's configured on OllaCore
        const currentModule = await ollaCoreRead.read.safetyModule() as `0x${string}`;
        const isConfigured = currentModule.toLowerCase() === addresses.SafetyModule.toLowerCase();

        // Read full SafetyModule state
        const [isPaused, coreAddress, depositCap, withdrawalMinimum, minRateDropBps, maxQueueRatioBps, maxAccountingDelay] =
          await Promise.all([
            safetyModuleRead.read.isPaused(),
            safetyModuleRead.read.CORE(),
            safetyModuleRead.read.depositCap(),
            safetyModuleRead.read.withdrawalMinimum(),
            safetyModuleRead.read.minRateDropBps(),
            safetyModuleRead.read.maxQueueRatioBps(),
            safetyModuleRead.read.maxAccountingDelay(),
          ]) as [boolean, `0x${string}`, bigint, bigint, bigint, bigint, bigint];

        return {
          scenario: "safety-module",
          success: true,
          data: {
            action: "read-state",
            isConfigured,
            configuredAddress: currentModule,
            isPaused,
            coreAddress,
            depositCap: depositCap.toString(),
            withdrawalMinimum: withdrawalMinimum.toString(),
            minRateDropBps: Number(minRateDropBps),
            maxQueueRatioBps: Number(maxQueueRatioBps),
            maxAccountingDelay: Number(maxAccountingDelay),
          },
        };
      }

      case "verify-breaker": {
        // Check if the safety module has been triggered (paused)
        const isPaused = await safetyModuleRead.read.isPaused() as boolean;

        // Read current OllaCore state for context
        const [exchangeRate, totalAssets] = await Promise.all([
          ollaCoreRead.read.exchangeRate(),
          ollaCoreRead.read.totalAssets(),
        ] as const) as [bigint, bigint];

        return {
          scenario: "safety-module",
          success: true,
          data: {
            action: "verify-breaker",
            breakerTriggered: isPaused,
            exchangeRate: exchangeRate.toString(),
            totalAssets: totalAssets.toString(),
          },
        };
      }

      case "warp-time": {
        const seconds = scenario.warpSeconds ?? 3601; // default: just over 1 hour

        // Zero the mock reward rate before warping to prevent massive reward
        // accumulation (tick() calculates rewards = rate × elapsed seconds).
        const rollupRead = getMockAztecRollup(addresses, clients.publicClient);
        const rollupWrite = getMockAztecRollup(addresses, clients.operatorWallet);
        const savedRate = await rollupRead.read.rewardRatePerSecond() as bigint;
        await rollupWrite.write.setRewardRatePerSecond([0n]);

        // Advance Anvil block timestamp
        await clients.publicClient.request({
          method: "evm_increaseTime" as any,
          params: [seconds],
        });
        // Mine a block so the new timestamp takes effect
        await clients.publicClient.request({
          method: "evm_mine" as any,
          params: [],
        });

        // Flush the elapsed time at rate 0 so lastTick resets
        await rollupWrite.write.tick([addresses.RewardsVaultProxy]);

        // Restore the original reward rate
        await rollupWrite.write.setRewardRatePerSecond([savedRate]);

        return {
          scenario: "safety-module",
          success: true,
          data: {
            action: "warp-time",
            warpedSeconds: seconds,
            savedRate: savedRate.toString(),
          },
        };
      }

      case "unpause": {
        const isPaused = await safetyModuleRead.read.isPaused() as boolean;
        if (!isPaused) {
          return {
            scenario: "safety-module",
            success: true,
            data: {
              action: "unpause",
              result: "already_unpaused",
            },
          };
        }

        // Unpause requires GUARDIAN_ROLE (deployer has it in local dev)
        const safetyModuleWrite = getSafetyModule(addresses, clients.operatorWallet);
        const tx = await safetyModuleWrite.write.unpause();

        return {
          scenario: "safety-module",
          success: true,
          txHash: tx,
          data: {
            action: "unpause",
            result: "unpaused",
          },
        };
      }

      default:
        return {
          scenario: "safety-module",
          success: false,
          error: `Unknown safety-module action: ${scenario.action}`,
        };
    }
  } catch (error) {
    return {
      scenario: "safety-module",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
