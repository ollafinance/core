import type { WalletClient, PublicClient } from "viem";
import { parseAbiItem } from "viem";
import type { ExternalExitScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { getMockAztecRollup, getStakingProviderRegistry, loadAbi } from "../client.js";

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

export async function executeExternalExit(
  scenario: ExternalExitScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses,
  _scenarioState: any,
  _runState: any
): Promise<ActionResult> {
  const rollup = getMockAztecRollup(addresses, clients.operatorWallet);
  const rollupRead = getMockAztecRollup(addresses, clients.publicClient);
  const registryRead = getStakingProviderRegistry(addresses, clients.publicClient);
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
        scenario: "external-exit",
        success: false,
        error: "No active attesters found on rollup (all may be exiting already)",
      };
    }

    // Pick attester to exit (default: last one to avoid disrupting other scenarios)
    const attesterIndex = scenario.exitAttesterIndex ?? (activeAttesters.length - 1);
    if (attesterIndex >= activeAttesters.length) {
      return {
        scenario: "external-exit",
        success: false,
        error: `Attester index ${attesterIndex} out of range (${activeAttesters.length} active attesters)`,
      };
    }
    const attester = activeAttesters[attesterIndex];

    // Read key count before
    const keyCountBefore = await registryRead.read.getQueueLength() as bigint;

    // Read current effective balance from rollup view
    const view = await rollupRead.read.getAttesterView([attester]) as any;
    const currentStake = view.effectiveBalance as bigint;

    // Simulate external exit: create an exit record with full stake amount
    // exitableAt = 0 makes it immediately finalizable
    const exitTx = await rollup.write.setExternalExit([
      attester,
      currentStake,
      0n, // exitableAt = 0 (immediately finalizable)
    ]);

    // Process the exit via computeAttesterState
    // This detects the exit and transitions the attester to Exiting status
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

    // Read key count after
    const keyCountAfter = await registryRead.read.getQueueLength() as bigint;

    return {
      scenario: "external-exit",
      success: true,
      data: {
        exitedAttester: attester,
        attesterIndex,
        stakeAmount: currentStake.toString(),
        keyCountBefore: keyCountBefore.toString(),
        keyCountAfter: keyCountAfter.toString(),
        remainingActiveAttesters: activeAttesters.length - 1,
        exitTx,
        computeTx,
      },
    };
  } catch (error) {
    return {
      scenario: "external-exit",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
