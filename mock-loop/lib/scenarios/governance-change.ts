import type { WalletClient, PublicClient } from "viem";
import type { GovernanceChangeScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { createUserWallet, getOllaGovernance, getOllaCore, loadAbi } from "../client.js";

export async function executeGovernanceChange(
  scenario: GovernanceChangeScenario,
  _tick: number,
  clients: { publicClient: PublicClient; operatorWallet: WalletClient },
  addresses: DeploymentAddresses
): Promise<ActionResult> {
  const newGovernanceWallet = createUserWallet(
    clients.publicClient.transport.url,
    scenario.newGovernancePrivateKey
  );
  const newGovernance = newGovernanceWallet.account?.address;

  if (!newGovernance) {
    return {
      scenario: "governance-change",
      success: false,
      error: "Failed to derive governance address from private key",
    };
  }

  try {
    const govWrite = getOllaGovernance(addresses, clients.operatorWallet);
    const govRead = getOllaGovernance(addresses, clients.publicClient);
    const govAbi = loadAbi("OllaGovernance");
    const govAddress = addresses.OllaGovernanceProxy as `0x${string}`;
    const coreRead = getOllaCore(addresses, clients.publicClient);

    // Schedule proposeGovernance via timelock (minDelay=0 for local dev)
    const proposeCalldata = {
      functionName: "proposeGovernance",
      args: [newGovernance],
    };
    const encodedPropose = (await clients.publicClient.readContract({
      address: govAddress,
      abi: govAbi,
      functionName: "hashOperation",
      args: [
        govAddress,
        0n,
        // We need the raw calldata; use encodeAbiParameters manually
        "0x" as `0x${string}`,
        "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
        "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
      ],
    })) as `0x${string}`;

    // Use viem's encodeFunctionData for the proposeGovernance call
    const { encodeFunctionData } = await import("viem");
    const proposeData = encodeFunctionData({
      abi: govAbi,
      functionName: "proposeGovernance",
      args: [newGovernance],
    });

    // Schedule + execute proposeGovernance through timelock
    const scheduleTx = await govWrite.write.schedule([
      govAddress,
      0n,
      proposeData,
      "0x0000000000000000000000000000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000000000000000000000000000",
      0n,
    ]);
    await clients.publicClient.waitForTransactionReceipt({ hash: scheduleTx });

    const executeTx = await govWrite.write.execute([
      govAddress,
      0n,
      proposeData,
      "0x0000000000000000000000000000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    ]);
    await clients.publicClient.waitForTransactionReceipt({ hash: executeTx });

    // New governance accepts directly on OllaGovernance
    const newGovGov = getOllaGovernance(addresses, newGovernanceWallet);
    const acceptTx = await newGovGov.write.acceptGovernance([]);
    await clients.publicClient.waitForTransactionReceipt({ hash: acceptTx });

    // Verify: read owner from OllaCore (should still be OllaGovernanceProxy)
    const coreOwner = await coreRead.read.owner() as `0x${string}`;
    const govAdmin = await govRead.read.governanceAdmin() as `0x${string}`;

    return {
      scenario: "governance-change",
      success: govAdmin.toLowerCase() === newGovernance.toLowerCase(),
      data: {
        proposed: newGovernance,
        coreOwner,
        governanceAdmin: govAdmin,
        scheduleTx,
        executeTx,
        acceptTx,
      },
    };
  } catch (error) {
    return {
      scenario: "governance-change",
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
