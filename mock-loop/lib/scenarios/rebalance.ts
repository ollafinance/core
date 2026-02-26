import type { WalletClient, PublicClient } from "viem";
import type { RebalanceScenario, DeploymentAddresses, ActionResult } from "../types.js";
import {
  getOllaCore,
  getStakingManager,
  getStakingProviderRegistry,
  loadAbi,
  createUserWallet,
} from "../client.js";

const REBALANCE_STEP_DONE = 6; // RebalanceStep.Done
const REBALANCE_STEP_PULL_UNSTAKED = 1; // RebalanceStep.PullUnstaked
const STAKE_FAILED_SELECTOR = "0xd101596a"; // Stake failed error selector
const INSUFFICIENT_KEYS_SELECTOR = "0x8f90cd97"; // StakingManager__InsufficientKeys selector
const REBALANCE_STEP_NAMES = ["Harvest", "PullUnstaked", "FinalizeWithdrawals", "InitiateUnstake", "StakeSurplus", "ComputeAttesterState", "Done"];

export async function executeRebalance(
  _scenario: RebalanceScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  // Use non-operator wallet when privateKey is provided (permissionless mode)
  const callerWallet = _scenario.privateKey
    ? createUserWallet(clients.publicClient.transport.url, _scenario.privateKey)
    : clients.operatorWallet;

  const ollaCore = getOllaCore(addresses, callerWallet);
  const ollaCoreRead = getOllaCore(addresses, clients.publicClient);
  const stakingManagerAbi = loadAbi("StakingManager");
  const stakingManagerAddress = addresses.StakingManagerProxy as `0x${string}`;
  const iterations: string[] = [];
  const stepHistory: { iter: number; step: number; stepName: string; stakeRemaining: string; unstakeRemaining: string }[] = [];
  let lastProgress: { step: number; stakeRemaining: bigint; unstakeRemaining: bigint } | null = null;
  let gasLimit: bigint | undefined;
  let gasBumped = false;
  let gasBumpCount = 0;
  const gasBumpSteps = [1_000_000n, 2_500_000n, 5_000_000n, 10_000_000n];
  let gasBumpIndex = 0;
  let chainGasLimit: bigint | null = null;
  let finalizeExitsRetries = 0;
  const MAX_FINALIZE_RETRIES = 3;

  try {
    let iteration = 0;
    let complete = false;
    const attesterGas = 500_000n;
    const preComputeTx = await callerWallet.writeContract({
      address: stakingManagerAddress,
      abi: stakingManagerAbi,
      functionName: "computeAttesterState",
      args: [],
      gas: attesterGas,
      chain: null,
      account: callerWallet.account,
    } as any);
    await clients.publicClient.waitForTransactionReceipt({ hash: preComputeTx });
    const gasThreshold = await ollaCoreRead.read.rebalanceGasThreshold() as bigint;
    const minGasLimit = gasBumpSteps[0];
    gasLimit = gasThreshold + 300_000n;
    if (gasLimit < minGasLimit) {
      gasLimit = minGasLimit;
    }
    chainGasLimit = (await clients.publicClient.getBlock()).gasLimit as bigint;

    while (!complete) {
      iteration++;

      // Safety check: prevent infinite loop
      if (iteration > 100) {
        throw new Error(`Rebalance did not complete after 100 iterations. Step history: ${JSON.stringify(stepHistory.slice(-10))}`);
      }

      // Call rebalance
      const txHash = await ollaCore.write.rebalance([], { gas: gasLimit });
      iterations.push(txHash);

      try {
        const receipt = await clients.publicClient.waitForTransactionReceipt({ hash: txHash });
        if (receipt.status === "reverted") {
          const progress = await ollaCoreRead.read.rebalanceProgress() as {
            step: number;
            stakeRemaining: bigint;
            unstakeRemaining: bigint;
          };
          const providerRegistry = getStakingProviderRegistry(addresses, clients.publicClient);
          const availableKeyCount = await providerRegistry.read.getQueueLength() as bigint;
          if (progress.step === 4 && availableKeyCount === 0n) {
            return {
              scenario: "rebalance",
              success: true,
              data: {
                iterations: iteration,
                transactions: iterations,
                stepHistory,
                note: "rebalance reverted during StakeSurplus with no provider keys; yielding until keys are added",
                availableKeyCount: availableKeyCount.toString(),
                gasBumped,
                gasBumpCount,
              },
            };
          }
          if (gasLimit && receipt.gasUsed >= (gasLimit * 90n) / 100n) {
            const nextLimit = gasBumpSteps[gasBumpIndex + 1];
            const cappedLimit = chainGasLimit ? (nextLimit > chainGasLimit ? chainGasLimit : nextLimit) : nextLimit;
            if (nextLimit !== undefined && cappedLimit > gasLimit) {
              gasBumpCount += 1;
              gasBumped = true;
              gasBumpIndex += 1;
              gasLimit = cappedLimit;
              console.log(`[rebalance] gas bump to ${gasLimit.toString()}`);
              stepHistory.push({
                iter: iteration,
                step: progress.step,
                stepName: "GasBump",
                stakeRemaining: progress.stakeRemaining.toString(),
                unstakeRemaining: progress.unstakeRemaining.toString(),
              });
              continue;
            }
            stepHistory.push({
              iter: iteration,
              step: progress.step,
              stepName: "GasBump",
              stakeRemaining: progress.stakeRemaining.toString(),
              unstakeRemaining: progress.unstakeRemaining.toString(),
            });
          }
          throw new Error(`rebalance reverted in tx ${txHash}`);
        }
      } catch (waitError) {
        const errorMessage = waitError instanceof Error ? waitError.message : String(waitError);
        if (
          errorMessage.toLowerCase().includes("out of gas") ||
          errorMessage.toLowerCase().includes("outofgas") ||
          errorMessage.toLowerCase().includes("intrinsic gas too low")
        ) {
          const nextLimit = gasBumpSteps[gasBumpIndex + 1];
          const cappedLimit = chainGasLimit ? (nextLimit > chainGasLimit ? chainGasLimit : nextLimit) : nextLimit;
          if (nextLimit !== undefined && gasLimit && cappedLimit > gasLimit) {
            gasBumpCount += 1;
            gasBumped = true;
            gasBumpIndex += 1;
            gasLimit = cappedLimit;
            console.log(`[rebalance] gas bump to ${gasLimit.toString()}`);
            stepHistory.push({
              iter: iteration,
              step: lastProgress?.step ?? 0,
              stepName: "GasBump",
              stakeRemaining: lastProgress?.stakeRemaining.toString() ?? "0",
              unstakeRemaining: lastProgress?.unstakeRemaining.toString() ?? "0",
            });
            continue;
          }
        }
        if (
          errorMessage.includes(STAKE_FAILED_SELECTOR) ||
          errorMessage.includes(INSUFFICIENT_KEYS_SELECTOR)
        ) {
          return {
            scenario: "rebalance",
            success: true,
            data: {
              iterations: iteration,
              transactions: iterations,
              stepHistory,
              note: "stake failed; likely insufficient provider keys or activation threshold too high",
              gasBumped,
              gasBumpCount,
            },
          };
        }
        return {
          scenario: "rebalance",
          success: false,
          error: errorMessage,
          data: {
            iterationsCompleted: iterations.length,
            stepHistory,
            gasBumped,
            gasBumpCount,
          },
        };
      }

      // Check if rebalance is complete by reading rebalanceProgress
      const progress = await ollaCoreRead.read.rebalanceProgress() as { step: number; stakeRemaining: bigint; unstakeRemaining: bigint };
      stepHistory.push({
        iter: iteration,
        step: progress.step,
        stepName: REBALANCE_STEP_NAMES[progress.step] ?? "Unknown",
        stakeRemaining: progress.stakeRemaining.toString(),
        unstakeRemaining: progress.unstakeRemaining.toString()
      });
      // Detect stuck state: no progress between iterations
      if (
        lastProgress &&
        progress.step === lastProgress.step &&
        progress.stakeRemaining === lastProgress.stakeRemaining &&
        progress.unstakeRemaining === lastProgress.unstakeRemaining
      ) {
        // When stuck at PullUnstaked, call finalizeExits() to move exiting attesters
        // through the exit queue, then retry the rebalance.
        if (progress.step === REBALANCE_STEP_PULL_UNSTAKED && finalizeExitsRetries < MAX_FINALIZE_RETRIES) {
          finalizeExitsRetries++;
          const stakingManager = getStakingManager(addresses, callerWallet);
          const stakingManagerRead = getStakingManager(addresses, clients.publicClient);
          const exitCountBefore = await stakingManagerRead.read.getPendingUnstakeCount() as bigint;
          // Use explicit gas limit — see finalize-exits.ts for rationale.
          const finalizeTx = await stakingManager.write.finalizeExits([], { gas: 1_000_000n });
          await clients.publicClient.waitForTransactionReceipt({ hash: finalizeTx });
          const exitCountAfter = await stakingManagerRead.read.getPendingUnstakeCount() as bigint;
          iterations.push(finalizeTx);
          stepHistory.push({
            iter: iteration,
            step: progress.step,
            stepName: `FinalizeExits (inline) exits:${exitCountBefore}->${exitCountAfter}`,
            stakeRemaining: progress.stakeRemaining.toString(),
            unstakeRemaining: progress.unstakeRemaining.toString(),
          });
          // Reset lastProgress so the next rebalance call can make progress
          lastProgress = null;
          continue;
        }

        return {
          scenario: "rebalance",
          success: true,
          data: {
            iterations: iteration,
            transactions: iterations,
            stepHistory,
            note: "rebalance made no progress; yielding until next tick",
            gasBumped,
            gasBumpCount,
          },
        };
      }

      lastProgress = progress;

      if (progress.step === REBALANCE_STEP_DONE) {
        complete = true;
      }
    }

    const postComputeTx = await callerWallet.writeContract({
      address: stakingManagerAddress,
      abi: stakingManagerAbi,
      functionName: "computeAttesterState",
      args: [],
      gas: attesterGas,
      chain: null,
      account: callerWallet.account,
    } as any);
    await clients.publicClient.waitForTransactionReceipt({ hash: postComputeTx });

    return {
      scenario: "rebalance",
      success: true,
      data: {
        iterations: iteration,
        transactions: iterations,
        stepHistory,
        postComputeTx,
        caller: callerWallet.account?.address,
        permissionless: !!_scenario.privateKey,
        gasBumped,
        gasBumpCount,
      },
    };
  } catch (error) {
    return {
      scenario: "rebalance",
      success: false,
      error: error instanceof Error ? error.message : String(error),
      data: {
        iterationsCompleted: iterations.length,
        stepHistory,
        gasBumped,
        gasBumpCount,
      },
    };
  }
}
