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
    // so refreshAttesterState sees stakedAmount > remaining → slashingDelta increases
    const slashTx = await rollup.write.setExternalExit([
      attester,
      remaining,
      0n, // exitableAt = 0 (immediately finalizable)
    ]);

    // Process the slashing via refreshAttesterState.
    // refreshAttesterState targets the specific attester directly.
    const computeTx = await clients.operatorWallet.writeContract({
      address: stakingManagerAddress,
      abi: stakingManagerAbi,
      functionName: "refreshAttesterState",
      args: [[attester]],
      gas: 500_000n,
      chain: null,
      account: clients.operatorWallet.account,
    } as any);
    await clients.publicClient.waitForTransactionReceipt({ hash: computeTx });
    const lastComputeTx = computeTx;
    const computeIterations = 1;

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
