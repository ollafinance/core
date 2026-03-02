import type { WalletClient, PublicClient } from "viem";
import type { RebalanceScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore, getStakingManager, loadAbi, createUserWallet } from "../client.js";

const REBALANCE_STEP_DONE = 6; // RebalanceStep.Done
const REBALANCE_STEP_PULL_UNSTAKED = 1; // RebalanceStep.PullUnstaked
const STAKE_FAILED_SELECTOR = "0xd101596a"; // Stake failed error selector
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
    const preComputeReceipt = await clients.publicClient.waitForTransactionReceipt({ hash: preComputeTx });
    if (preComputeReceipt.status === "reverted") {
      return {
        scenario: "rebalance",
        success: false,
        error: `pre-compute computeAttesterState reverted in tx ${preComputeTx}`,
        data: { iterationsCompleted: 0, stepHistory },
      };
    }
    const gasThreshold = await ollaCoreRead.read.rebalanceGasThreshold() as bigint;
    const minGasLimit = 1_000_000n;
    gasLimit = gasThreshold + 300_000n;
    if (gasLimit < minGasLimit) {
      gasLimit = minGasLimit;
    }

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
          throw new Error(`rebalance reverted in tx ${txHash}`);
        }
      } catch (waitError) {
        if (waitError instanceof Error && waitError.message.includes(STAKE_FAILED_SELECTOR)) {
          return {
            scenario: "rebalance",
            success: true,
            data: {
              iterations: iteration,
              transactions: iterations,
              stepHistory,
              note: "stake failed; likely insufficient provider keys or activation threshold too high",
            },
          };
        }
        return {
          scenario: "rebalance",
          success: false,
          error: waitError instanceof Error ? waitError.message : String(waitError),
          data: {
            iterationsCompleted: iterations.length,
            stepHistory,
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
      },
    };
  }
}
