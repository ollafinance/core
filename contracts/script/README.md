# Deployment Scripts

This directory contains a modular deployment system for Olla contracts.

## Structure

```
script/
├── Deploy.s.sol              # Main orchestrator
├── base/
│   └── BaseDeployer.s.sol    # Shared utilities (JSON, logging)
├── config/
│   ├── Config.s.sol          # Base config struct
│   ├── Local.s.sol           # Anvil configuration
│   └── Testnet.s.sol         # Testnet configuration
└── deployers/
    ├── Mocks.s.sol           # Mock contracts deployer
    ├── OllaCore.s.sol        # OllaCore deployer
    └── StAztec.s.sol         # StAztec deployer
```

## Quick Start

### Local Development

```bash
# Terminal 1: Start Anvil
yarn dev:anvil

# Terminal 2: Deploy contracts
yarn deploy:local
```

### Testnet Deployment

```bash
# Set your private key and deploy
PRIVATE_KEY=0x... yarn deploy:testnet
```

## Deployment Output

After deployment, a JSON file is created in `contracts/deployments/`:

```json
{
  "network": "local",
  "chainId": 31337,
  "deployer": "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
  "addresses": {
    "MockAztec": "0x...",
    "MockStakingManager": "0x...",
    "OllaCoreImplementation": "0x...",
    "OllaCoreProxy": "0x...",
    "StAztec": "0x..."
  }
}
```

## Adding a New Contract

### 1. Create the Deployer

Create a new file in `script/deployers/`:

```solidity
// script/deployers/MyContract.s.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { BaseDeployer, console2 } from "../base/BaseDeployer.s.sol";
import { DeployConfig } from "../config/Config.s.sol";
import { MyContract } from "src/core/MyContract.sol";

contract MyContractDeployer is BaseDeployer {
    function deploy(
        DeployConfig memory config,
        address dependency // any dependencies from other deployers
    ) external returns (address) {
        vm.startBroadcast(config.deployerPrivateKey);

        MyContract myContract = new MyContract(dependency);
        _logDeployment("MyContract", address(myContract));

        vm.stopBroadcast();

        return address(myContract);
    }
}
```

### 2. Add to Deploy.s.sol

Update the main orchestrator:

```solidity
// 1. Import the deployer
import { MyContractDeployer } from "./deployers/MyContract.s.sol";

contract DeployScript is BaseDeployer {
    // 2. Declare the deployer
    MyContractDeployer internal myContractDeployer;

    function setUp() public {
        // 3. Initialize the deployer
        myContractDeployer = new MyContractDeployer();
    }

    function run() public {
        // ... existing code ...

        // 4. Deploy your contract (after its dependencies)
        console2.log("\n--- Deploying MyContract ---");
        address myContract = myContractDeployer.deploy(config, someDependency);
        json = _addAddressToJson(json, "MyContract", myContract, false);

        // ... rest of deployment ...
    }
}
```

### 3. Update Config (if needed)

If your contract needs environment-specific configuration, add fields to `DeployConfig` in `config/Config.s.sol`:

```solidity
struct DeployConfig {
    // ... existing fields ...
    
    // Add your new config
    address myExternalDependency;
    uint256 myParameter;
}
```

Then update each environment config (`Local.s.sol`, `Testnet.s.sol`) with appropriate values.

## Environment Configuration

### Local (Anvil)

- **File:** `config/Local.s.sol`
- **Chain ID:** 31337
- **Mocks:** Deployed automatically
- **Private Key:** Uses default Anvil key (can override with `PRIVATE_KEY` env var)

### Testnet (Sepolia)

- **File:** `config/Testnet.s.sol`
- **Chain ID:** 11155111
- **Mocks:** Not deployed (use real contract addresses)
- **Private Key:** Required via `PRIVATE_KEY` env var

## Utilities

### BaseDeployer Helpers

```solidity
// Log a deployment
_logDeployment("ContractName", address(contract));

// Read address from previous deployment
address addr = _readDeployment("local", "OllaCoreProxy");

// Try to read (returns address(0) if not found)
address addr = _tryReadDeployment("local", "OllaCoreProxy");

// Check if deployment file exists
bool exists = _deploymentExists("local");
```

## Tips

1. **Order matters:** Deploy contracts in dependency order (e.g., OllaCore before StAztec)

2. **Incremental deploys:** Use `_tryReadDeployment()` to skip already-deployed contracts

3. **Testing deployers:** Run with `--dry-run` to simulate without broadcasting:
   ```bash
   cd contracts && forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545
   ```

4. **Verify on Etherscan:** The `deploy:testnet` command includes `--verify` flag
