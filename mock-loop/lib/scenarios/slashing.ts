import type { WalletClient, PublicClient } from "viem";
import { parseAbiItem } from "viem";
import type { SlashingScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getMockAztecRollup, getOllaCore, loadAbi } from "../client.js";

/**
 * Discover actively-validating attester addresses by reading StakedWithProvider
 * events from StakingManager, then checking getAttesterView on the rollup.
 * Only includes attesters that are VALIDATING (have a stake and no exit record).
 */
async function findActiveAttesters(
  publicClient: PublicClient,
  stakingManagerAddress: `0x${string}`,
  rollupRead: any
): Promise<`0x${string}`[]> {
  const logs = await publicClient.getLogs({
    address: stakingManagerAddress,
    event: parseAbiItem("event StakedWithProvider(address indexed attester, uint256 indexed amount)"),
    fromBlock: 0n,
  });

  // Deduplicate and verify each attester is actively validating (no exit record)
  const seen = new Set<string>();
  const active: `0x${string}`[] = [];
  for (const log of logs) {
    const attester = log.args.attester as `0x${string}`;
    if (seen.has(attester.toLowerCase())) continue;
    seen.add(attester.toLowerCase());

    const view = await rollupRead.read.getAttesterView([attester]) as any;
    // Status enum: 0=NONE, 1=VALIDATING, 2=EXITING, 3=ZOMBIE
    if (Number(view.status) === 1 && view.effectiveBalance > 0n) {
      active.push(attester);
    }
  }
  return active;
}

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

    // Process the slashing via computeAttesterState
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
        computeTx,
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
