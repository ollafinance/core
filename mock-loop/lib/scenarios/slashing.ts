import type { WalletClient, PublicClient } from "viem";
import type { SlashingScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getMockAztecRollup, getOllaCore, loadAbi } from "../client.js";
import { findActiveAttesters } from "./attesters.js";

export async function executeSlashing(
  scenario: SlashingScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses,
  _scenarioState: any,
  _runState: any
): Promise<ActionResult> {
  const rollup = getMockAztecRollup(addresses, clients.operatorWallet);
  const rollupRead = getMockAztecRollup(addresses, clients.publicClient);
  const ollaCoreRead = getOllaCore(addresses, clients.publicClient);
  const stakingManagerAbi = loadAbi("StakingManager");
  const stakingManagerAddress = addresses.StakingManagerProxy as `0x${string}`;

  try {
    // Discover actively-validating attesters (excludes those already exiting)
    const activeAttesters = await findActiveAttesters(
      clients.publicClient,
      stakingManagerAddress,
      rollupRead
    );

    if (activeAttesters.length === 0) {
      return {
        scenario: "slashing",
        success: false,
        error: "No active attesters found on rollup (all may be exiting already)",
      };
    }

    // Pick target attester
    const attesterIndex = scenario.targetAttesterIndex ?? 0;
    if (attesterIndex >= activeAttesters.length) {
      return {
        scenario: "slashing",
        success: false,
        error: `Attester index ${attesterIndex} out of range (${activeAttesters.length} active attesters)`,
      };
    }
    const attester = activeAttesters[attesterIndex];

    // Read current effective balance from rollup view
    const view = await rollupRead.read.getAttesterView([attester]) as any;
    const currentStake = view.effectiveBalance as bigint;

    // Calculate slash amount and remaining
    const slashAmountBps = BigInt(scenario.slashAmountBps);
    const slashAmount = (currentStake * slashAmountBps) / 10_000n;
    const remaining = currentStake - slashAmount;

    // Read exchange rate before
    const exchangeRateBefore = await ollaCoreRead.read.exchangeRate() as bigint;

    // Simulate slashing: create an external exit with reduced amount
    // This makes effectiveBalance = 0 and exit.amount = remaining,
    // so computeAttesterState sees stakedAmount > remaining → slashingDelta increases
    const slashTx = await rollup.write.setExternalExit([
      attester,
      remaining,
      0n, // exitableAt = 0 (immediately finalizable)
    ]);

    // Process the slashing via computeAttesterState.
    // computeAttesterState is incremental and may not process the targeted
    // attester in a single call, so loop until the attester is no longer
    // VALIDATING (status 1).
    const MAX_COMPUTE_ITERATIONS = 10;
    let computeIterations = 0;
    let lastComputeTx: `0x${string}` | undefined;

    for (let i = 0; i < MAX_COMPUTE_ITERATIONS; i++) {
      const computeTx = await clients.operatorWallet.writeContract({
        address: stakingManagerAddress,
        abi: stakingManagerAbi,
        functionName: "computeAttesterState",
        args: [],
        gas: 500_000n,
        chain: null,
        account: clients.operatorWallet.account,
      } as any);
      await clients.publicClient.waitForTransactionReceipt({ hash: computeTx });
      lastComputeTx = computeTx;
      computeIterations = i + 1;

      // Check if the attester has been processed (no longer VALIDATING)
      const postView = await rollupRead.read.getAttesterView([attester]) as any;
      if (Number(postView.status) !== 1) {
        break;
      }
    }

    // Read exchange rate after
    const exchangeRateAfter = await ollaCoreRead.read.exchangeRate() as bigint;

    return {
      scenario: "slashing",
      success: true,
      data: {
        attester,
        attesterIndex,
        originalStake: currentStake.toString(),
        slashAmountBps: scenario.slashAmountBps,
        slashAmount: slashAmount.toString(),
        remaining: remaining.toString(),
        exchangeRateBefore: exchangeRateBefore.toString(),
        exchangeRateAfter: exchangeRateAfter.toString(),
        slashTx,
        computeTx: lastComputeTx,
        computeIterations,
      },
    };
  } catch (error) {
    return {
      scenario: "slashing",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
