# Sepolia Deployment Script Refactor

## Problem

The deploy script (`Deploy.s.sol`) gated StakingManager, StakingProviderRegistry, and SafetyModule deployment behind `deployMocks`. These are Olla-owned contracts that should **always** be deployed — only `MockAztec`, `MockAztecRollup`, and `MockAztecRollupRegistry` are truly mock-specific.

## Three deployment scenarios now supported

1. **Real Aztec on Sepolia** (`DEPLOY_ENV=testnet`) — uses real AZTEC token + Registry
2. **Mocked Aztec on Sepolia** (`DEPLOY_ENV=testnet-mocked`) — deploys mock token + rollup
3. **Local Anvil** (`DEPLOY_ENV=local`) — unchanged behavior

---

## Changes by file

### 1. `contracts/script/config/Config.s.sol`

- Replaced `address stakingManager` with `address rollupRegistry` in `DeployConfig` struct
- `stakingManager` was only needed to pass a "pre-existing" address in the non-mock path; now always deployed by script
- `rollupRegistry` holds the Aztec Registry address (real or mock-provided)

### 2. `contracts/script/config/Testnet.s.sol`

- Set `asset: 0x5595cb9ED193cAc2C0Bc5393313bc6115817954B` (real AZTEC token on Sepolia)
- Set `rollupRegistry: 0xA0BFb1B494FB49041e5c6e8c2C1BE09cD171c6Ba` (real Aztec Registry on Sepolia)
- Set `timelockMinDelay: 0` (allows atomic schedule+execute wiring during initial deploy; can be increased later via governance)
- `deployMocks: false` (kept)

### 3. `contracts/script/config/TestnetMocked.s.sol` *(new file)*

- `deployMocks: true`, `chainId: 11155111` (Sepolia)
- `asset: address(0)`, `rollupRegistry: address(0)` — populated by mock deployer at runtime
- `timelockMinDelay: 0`
- Env name: `"testnet-mocked"`

### 4. `contracts/script/config/Local.s.sol`

- `stakingManager: address(0)` → `rollupRegistry: address(0)` (struct field rename)

### 5. `contracts/script/deployers/StakingStack.s.sol` *(new file)*

- Extracted from `MocksDeployer._deployStakingStackInternal()`
- Same logic but **no `deployMocks` guard** — always callable
- Deploys StakingManager + StakingProviderRegistry implementations and proxies, initializes both
- Uses `config.deployer` for provider admin and rewards recipient (changeable later via governance)

### 6. `contracts/script/deployers/Mocks.s.sol`

- Removed `deployStakingStack()`, `_deployStakingStackInternal()`, and `StakingStackParams` struct
- Kept `deployAssetAndRollup()` (MockAztec, MockAztecRollup, MockAztecRollupRegistry)
- Kept `deployLzEndpointMock()`
- Removed unused imports (`ERC1967Proxy`, `StakingManager`, `StakingProviderRegistry`)

### 7. `contracts/script/Deploy.s.sol` — main refactor

**New deployer:**
- Added `StakingStackDeployer` + `TestnetMockedConfig` imports

**Mock block (step 4) — only deploys mock externals:**

```solidity
if (config.deployMocks) {
    (asset, rollup, rollupRegistry) = _mocksDeployer.deployAssetAndRollup(config);
} else {
    asset = config.asset;
    rollupRegistry = config.rollupRegistry;
    require(asset != address(0), "Deploy: asset address required");
    require(rollupRegistry != address(0), "Deploy: rollupRegistry address required");
}
```

**Staking stack — always deployed (after RewardsAccumulator):**

```solidity
(stakingManagerImpl, stakingManager, stakingProviderRegistryImpl, stakingProviderRegistry) =
    _stakingStackDeployer.deploy(config, ollaCoreProxy, rewardsAccumulator, asset, rollupRegistry, ollaGovProxy);
```

**Provider keys + rollup mock wiring — mock-only:**

```solidity
if (config.deployMocks) {
    // Seed dummy provider keys
    // Set rewardsCoinbase on mock rollup
    // Write mock addresses to JSON
}
```

**SafetyModule — always deployed:**

- `ollaGovProxy` as admin (governance controls config)
- `config.deployer` as guardian (deployer can pause directly, no timelock delay)

**Wiring — gated on `timelockMinDelay == 0` (not `deployMocks`):**

```solidity
if (config.timelockMinDelay == 0) {
    if (config.chainId == 31337) { vm.warp(block.timestamp + 1); }
    // schedule+execute: setVault, unpause core, unpause vault
}
```

- `vm.warp` only needed on Anvil (block.timestamp starts at 1, collides with OZ sentinel)
- On Sepolia with `timelockMinDelay == 0`, wiring executes atomically without warp

**`_loadConfig()` — added `"testnet-mocked"` branch**

---

## Deployment commands

```bash
# Real Aztec on Sepolia
DEPLOY_ENV=testnet PRIVATE_KEY=<key> forge script contracts/script/Deploy.s.sol \
  --broadcast --rpc-url sepolia --verify

# Mocked Aztec on Sepolia
DEPLOY_ENV=testnet-mocked PRIVATE_KEY=<key> forge script contracts/script/Deploy.s.sol \
  --broadcast --rpc-url sepolia

# Local (unchanged)
DEPLOY_ENV=local forge script contracts/script/Deploy.s.sol --broadcast --rpc-url local
```

## Key design decisions

- **`timelockMinDelay == 0` as wiring gate** instead of `deployMocks` — both testnet and testnet-mocked need atomic wiring, and this is semantically correct (it's the timelock that determines whether schedule+execute is atomic)
- **`vm.warp` only on Anvil** — Sepolia has real block timestamps so no sentinel collision
- **Deployer as SafetyModule guardian** — allows fast emergency pause without going through timelock; governance (admin) controls all other config
- **StakingStackDeployer as standalone** — clean separation; mock deployer only handles truly external mock contracts

## Verification

1. `forge build` — all contracts compile (889 tests pass, 0 failures)
2. Dry-run: `DEPLOY_ENV=testnet PRIVATE_KEY=<key> forge script contracts/script/Deploy.s.sol --rpc-url sepolia` (no `--broadcast`)
3. Check generated `deployments/testnet.json` has all expected addresses
