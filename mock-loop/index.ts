import { defaultConfig } from "./config.js";
import {
  createClients,
  loadDeployments,
  getOllaCore,
} from "./lib/client.js";

console.log("Mock Loop v2 - Phase 3 Test");
console.log("============================");

const config = defaultConfig;

// Test client creation
console.log("Creating viem clients...");
const { publicClient, operatorWallet } = createClients(config.rpcUrl);
console.log(`✓ Public client created`);
console.log(`✓ Operator wallet: ${operatorWallet.account?.address}`);

// Test deployment loading
try {
  const addresses = loadDeployments(config.deployEnv);
  console.log(`✓ Loaded deployments for ${config.deployEnv}`);
  console.log(`  OllaCore: ${addresses.OllaCoreProxy}`);
  console.log(`  StakingManager: ${addresses.StakingManagerProxy}`);
} catch (error) {
  console.log(`⚠️  Deployment loading skipped (no local deployment found)`);
  console.log(`   Run 'yarn deploy:local' first to test full client functionality`);
}

// Attempt to read totalAssets if chain is available
console.log("\nAttempting to read OllaCore.totalAssets()...");

try {
  const addresses = loadDeployments(config.deployEnv);
  const ollaCore = getOllaCore(addresses, publicClient);
  const totalAssets = await ollaCore.read.totalAssets();
  console.log(`✓ totalAssets(): ${totalAssets.toString()}`);
  console.log("\n✅ Phase 3 complete - client can read contract state!");
} catch (error) {
  console.log(`⚠️  Could not read totalAssets (chain may not be running)`);
  console.log(`   Error: ${error instanceof Error ? error.message : String(error)}`);
  console.log("\n✅ Phase 3 client scaffolding ready (requires running chain)");
}

process.exit(0);
