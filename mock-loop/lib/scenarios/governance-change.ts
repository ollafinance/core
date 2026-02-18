import type { WalletClient, PublicClient } from "viem";
import type { GovernanceChangeScenario, DeploymentAddresses, ActionResult } from "../types.js";
import { createUserWallet, getOllaCore } from "../client.js";

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
    const adminCore = getOllaCore(addresses, clients.operatorWallet);
    const coreRead = getOllaCore(addresses, clients.publicClient);

    const proposeTx = await adminCore.write.proposeGovernance([newGovernance]);
    await clients.publicClient.waitForTransactionReceipt({ hash: proposeTx });
    const newGovCore = getOllaCore(addresses, newGovernanceWallet);
    const acceptTx = await newGovCore.write.acceptGovernance([]);
    await clients.publicClient.waitForTransactionReceipt({ hash: acceptTx });

    const operatorAddress = clients.operatorWallet.account?.address;
    let operatorRoleTx: `0x${string}` | undefined;
    if (operatorAddress) {
      const operatorRole = await coreRead.read.OPERATOR_ROLE() as `0x${string}`;
      operatorRoleTx = await newGovCore.write.grantRole([operatorRole, operatorAddress]);
      await clients.publicClient.waitForTransactionReceipt({ hash: operatorRoleTx });
    }

    const currentGovernance = await coreRead.read.governance() as `0x${string}`;

    return {
      scenario: "governance-change",
      success: currentGovernance.toLowerCase() === newGovernance.toLowerCase(),
      data: {
        proposed: newGovernance,
        currentGovernance,
        proposeTx,
        acceptTx,
        operatorRoleTx,
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
