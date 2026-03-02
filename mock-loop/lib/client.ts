import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Account,
  type Address,
  type Abi,
  getContract,
  type GetContractReturnType,
} from "viem";
// Anvil chain (chain id 31337)
const anvilChain = {
  id: 31337,
  name: "Anvil",
  nativeCurrency: {
    decimals: 18,
    name: "Ether",
    symbol: "ETH",
  },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
    public: { http: ["http://127.0.0.1:8545"] },
  },
};
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "fs";
import { resolve } from "path";
import { fileURLToPath } from "url";
import type { DeploymentAddresses, DeploymentJson } from "./types.js";

const __dirname = fileURLToPath(new URL(".", import.meta.url));

// Anvil default accounts
export const ANVIL_ACCOUNTS: Account[] = [
  {
    address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    type: "json-rpc",
  }, // Account 0 - operator
  {
    address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    type: "json-rpc",
  }, // Account 1 - user
  {
    address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    type: "json-rpc",
  }, // Account 2
  {
    address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    type: "json-rpc",
  }, // Account 3
  {
    address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
    type: "json-rpc",
  }, // Account 4
];

// Cache for loaded ABIs
const abiCache = new Map<string, Abi>();

export function loadAbi(contractName: string): Abi {
  if (abiCache.has(contractName)) {
    return abiCache.get(contractName)!;
  }

  const abiPath = resolve(
    __dirname,
    "../../contracts/out",
    `${contractName}.sol`,
    `${contractName}.json`
  );

  try {
    const content = readFileSync(abiPath, "utf-8");
    const parsed = JSON.parse(content);
    const abi = parsed.abi as Abi;
    abiCache.set(contractName, abi);
    return abi;
  } catch (error) {
    throw new Error(
      `Failed to load ABI for ${contractName} from ${abiPath}. ` +
        `Did you run 'forge build'? Error: ${error}`
    );
  }
}

export function loadDeployments(env: string): DeploymentAddresses {
  const deploymentPath = resolve(
    __dirname,
    "../../contracts/deployments",
    `${env}.json`
  );

  try {
    const content = readFileSync(deploymentPath, "utf-8");
    const deployment = JSON.parse(content) as DeploymentJson;
    return deployment.addresses;
  } catch (error) {
    throw new Error(
      `Failed to load deployment for ${env} from ${deploymentPath}. ` +
        `Did you run 'yarn deploy:${env}'? Error: ${error}`
    );
  }
}

export function createClients(rpcUrl: string): {
  publicClient: PublicClient;
  operatorWallet: WalletClient;
} {
  const transport = http(rpcUrl);

  const publicClient = createPublicClient({
    chain: anvilChain,
    transport,
  });

  const operatorWallet = createWalletClient({
    chain: anvilChain,
    transport,
    account: ANVIL_ACCOUNTS[0],
  });

  return { publicClient, operatorWallet };
}

export function createUserWallet(
  rpcUrl: string,
  privateKey: string
): WalletClient {
  const transport = http(rpcUrl);
  const account = privateKeyToAccount(privateKey as `0x${string}`);

  return createWalletClient({
    chain: anvilChain,
    transport,
    account,
  });
}

export function getContractInstance<TAbi extends Abi>(
  contractName: string,
  address: Address,
  client: PublicClient | WalletClient
): GetContractReturnType<TAbi, typeof client> {
  const abi = loadAbi(contractName) as TAbi;
  return getContract({
    abi,
    address,
    client,
  }) as GetContractReturnType<TAbi, typeof client>;
}

// Pre-loaded contract instances helpers
export function getOllaCore(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance("OllaCore", addresses.OllaCoreProxy as Address, client);
}

export function getOllaVault(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance("OllaVault", addresses.OllaVaultProxy as Address, client);
}

export function getStakingManager(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance(
    "StakingManager",
    addresses.StakingManagerProxy as Address,
    client
  );
}

export function getWithdrawalQueue(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance(
    "WithdrawalQueue",
    addresses.WithdrawalQueueProxy as Address,
    client
  );
}

export function getAsset(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  // Asset is MockAztec which has mint function
  return getContractInstance("MockAztec", addresses.Asset as Address, client);
}

export function getStAztec(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance("ERC20", addresses.StAztec as Address, client);
}

export function getStakingProviderRegistry(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance(
    "MockStakingProviderRegistry",
    addresses.StakingProviderRegistryProxy as Address,
    client
  );
}

export function getMockAztecRollup(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance(
    "MockAztecRollup",
    addresses.MockAztecRollup as Address,
    client
  );
}

export function getRewardsVault(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance(
    "MockRewardsVault",
    addresses.RewardsCollectorProxy as Address,
    client
  );
}

export function getOllaGovernance(
  addresses: DeploymentAddresses,
  client: PublicClient | WalletClient
) {
  return getContractInstance(
    "OllaGovernance",
    addresses.OllaGovernanceProxy as Address,
    client
  );
}
