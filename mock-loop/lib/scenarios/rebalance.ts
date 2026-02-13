import type { WalletClient, PublicClient } from "viem";
import type { RebalanceScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getOllaCore, getStakingManager, loadAbi } from "../client.js";

const REBALANCE_STEP_DONE = 5; // RebalanceStep.Done
const STAKE_FAILED_SELECTOR = "0xd101596a"; // Stake failed error selector
const REBALANCE_STEP_NAMES = ["Harvest", "PullUnstaked", "FinalizeWithdrawals", "InitiateUnstake", "StakeSurplus", "Done"];

export async function executeRebalance(
  _scenario: RebalanceScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  const ollaCore = getOllaCore(addresses, clients.operatorWallet);
  const ollaCoreRead = getOllaCore(addresses, clients.publicClient);
  const stakingManager = getStakingManager(addresses, clients.operatorWallet);
  const stakingManagerAbi = loadAbi("StakingManager");
  const stakingManagerAddress = addresses.StakingManagerProxy as `0x${string}`;
  const iterations: string[] = [];
  const stepHistory: { iter: number; step: number; stepName: string; stakeRemaining: string; unstakeRemaining: string }[] = [];
  let gasLimit: bigint | undefined;

  try {
    let iteration = 0;
    let complete = false;
    const attesterGas = 500_000n;
    const preComputeTx = await clients.operatorWallet.writeContract({
      address: stakingManagerAddress,
      abi: stakingManagerAbi,
      functionName: "computeAttesterState",
      args: [],
      gas: attesterGas,
      chain: null,
      account: clients.operatorWallet.account,
    } as any);
    await clients.publicClient.waitForTransactionReceipt({ hash: preComputeTx });
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
      if (progress.step === REBALANCE_STEP_DONE) {
        complete = true;
      }
    }

    const postComputeTx = await clients.operatorWallet.writeContract({
      address: stakingManagerAddress,
      abi: stakingManagerAbi,
      functionName: "computeAttesterState",
      args: [],
      gas: attesterGas,
      chain: null,
      account: clients.operatorWallet.account,
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
