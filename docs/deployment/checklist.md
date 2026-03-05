# Deployment Checklist

## Environments

| DEPLOY_ENV | Chain | Mocks | Description |
|---|---|---|---|
| `local` | Anvil (31337) | Yes | Local dev — everything mocked, default Anvil key |
| `testnet-mocked` | Sepolia (11155111) | Yes | Sepolia with mock Aztec token + rollup |
| `testnet` | Sepolia (11155111) | No | Sepolia with real Aztec contracts |

---

## 1. Pre-deployment preparation

### Environment variables

| Variable | Required | Environments | Description |
|---|---|---|---|
| `DEPLOY_ENV` | Yes | All | One of `local`, `testnet-mocked`, `testnet` |
| `PRIVATE_KEY` | Yes (non-local) | `testnet`, `testnet-mocked` | Deployer EOA private key (hex, no `0x` prefix) |
| `LZ_ENDPOINT` | Optional | `testnet` | LayerZero EndpointV2 address for stAztec bridging. If unset, OFT adapter is skipped. |
| `PROVIDER_KEY_COUNT` | Optional | `local`, `testnet-mocked` | Number of dummy provider keys to seed (default: 5) |

### Hardcoded addresses to verify before deploying

These live in the config files under `contracts/script/config/`. Review and update them as needed.

#### `Testnet.s.sol` (real Aztec on Sepolia)

- [ ] `asset` — AZTEC token on Sepolia (currently `0x5595cb9ED193cAc2C0Bc5393313bc6115817954B`)
- [ ] `rollupRegistry` — Aztec Registry on Sepolia (currently `0xA0BFb1B494FB49041e5c6e8c2C1BE09cD171c6Ba`)
- [ ] `governance` — currently set to `deployer` (TODO: replace with real governance multisig)
- [ ] `treasury` — currently set to `deployer` (TODO: replace with real treasury address)
- [ ] `providerAdmin` — currently set to `deployer` (TODO: replace with real provider admin); used as both StakingProviderRegistry provider admin and rewards recipient
- [ ] `timelockMinDelay` — currently `0` for atomic wiring; increase via governance post-deploy
- [ ] `protocolFeeBP` — currently `500` (5%)
- [ ] `treasuryFeeSplitBP` — currently `5000` (50%)

#### `TestnetMocked.s.sol` (mocked Aztec on Sepolia)

- [ ] `governance` — set to `deployer` (OK for testing)
- [ ] `treasury` — set to `deployer` (OK for testing)
- [ ] `providerAdmin` — set to `deployer` (OK for testing)
- [ ] `asset` and `rollupRegistry` — must be `address(0)` (populated by mock deployer)

#### `Local.s.sol` (Anvil)

- [ ] No changes needed — uses default Anvil key and deploys everything locally

### Deployer account

- [ ] Deployer EOA has enough Sepolia ETH for gas (testnet deploys)
- [ ] Deployer EOA private key is correct and corresponds to the intended address
- [ ] Understand that the deployer becomes SafetyModule **guardian** (can emergency-pause) — changeable later via governance
- [ ] `providerAdmin` is set to the correct address — this controls StakingProviderRegistry provider admin and rewards recipient from day one

### Build

- [ ] Dependencies installed: `forge soldeer install` (from `contracts/`)
- [ ] Clean build passes: `forge build --skip test` (from `contracts/`)
- [ ] Tests pass: `forge test` (from `contracts/`)

---

## 2. Deployment steps

All commands run from the `contracts/` directory.

### Local (Anvil)

```bash
# Start Anvil in a separate terminal
anvil

# Deploy
DEPLOY_ENV=local forge script script/Deploy.s.sol --broadcast --rpc-url http://127.0.0.1:8545
```

### Testnet — mocked Aztec on Sepolia

```bash
# Dry-run first (no --broadcast)
DEPLOY_ENV=testnet-mocked PRIVATE_KEY=<key> forge script script/Deploy.s.sol --rpc-url sepolia

# If dry-run looks good, broadcast
DEPLOY_ENV=testnet-mocked PRIVATE_KEY=<key> forge script script/Deploy.s.sol --broadcast --rpc-url sepolia
```

### Testnet — real Aztec on Sepolia

```bash
# Dry-run first (no --broadcast)
DEPLOY_ENV=testnet PRIVATE_KEY=<key> forge script script/Deploy.s.sol --rpc-url sepolia

# If dry-run looks good, broadcast and verify on Etherscan
DEPLOY_ENV=testnet PRIVATE_KEY=<key> forge script script/Deploy.s.sol \
  --broadcast --rpc-url sepolia --verify
```

---

## 3. Post-deployment verification

- [ ] Check `deployments/<env-name>.json` was written with all expected addresses
- [ ] Verify OllaCore is unpaused (if `timelockMinDelay == 0`)
- [ ] Verify OllaVault is unpaused (if `timelockMinDelay == 0`)
- [ ] Verify OllaGovernance.core() points to OllaCore proxy
- [ ] Verify OllaCore.vault() points to OllaVault proxy
- [ ] Verify deployer's DEFAULT_ADMIN_ROLE on OllaGovernance was renounced
- [ ] Verify SafetyModule guardian is the deployer EOA
- [ ] Verify SafetyModule admin is OllaGovernance proxy
- [ ] Verify StakingProviderRegistry provider admin is `config.providerAdmin`
- [ ] Verify StakingProviderRegistry rewards recipient is `config.providerAdmin`
- [ ] Etherscan verification succeeded (for `--verify` deploys)

### Contracts deployed (all environments)

| Contract | Type | Notes |
|---|---|---|
| OllaGovernance | impl + proxy | TimelockController-based governance |
| OllaCore | impl + proxy | Core accounting, owned by OllaGovernance |
| OllaVault | impl + proxy | ERC-7575 vault |
| StAztec | standalone | ERC-20 share token, minter = OllaVault |
| WithdrawalQueue | impl + proxy | FIFO queue, admin = OllaGovernance |
| RewardsAccumulator | impl + proxy | Linked to OllaCore |
| StakingManager | impl + proxy | Always deployed (not mock-gated) |
| StakingProviderRegistry | impl + proxy | Always deployed; provider admin + rewards recipient = `config.providerAdmin` |
| SafetyModule | standalone | Guardian = deployer, admin = OllaGovernance |

### Additional contracts and setup (mock environments only)

| Contract | Type | Notes |
|---|---|---|
| MockAztec | standalone | ERC-20 mock staking token |
| MockAztecRollup | standalone | Mock rollup with `tick()` rewards |
| MockAztecRollupRegistry | standalone | Points to MockAztecRollup |
| EndpointV2Mock | standalone | Mock LZ endpoint for OFT adapter |

Dummy attester keys are seeded into the StakingProviderRegistry only in mock environments (`local`, `testnet-mocked`). For real deployments (`testnet`), keys must be registered separately by the provider admin after deploy.

---

## 4. Post-deploy governance actions (when ready)

These are not part of the deploy script — they require separate governance proposals or direct calls:

- [ ] Increase `timelockMinDelay` on OllaGovernance (currently 0 for atomic wiring)
- [ ] Transfer `governance` and `treasury` roles from deployer EOA to real multisig addresses
- [ ] Transfer SafetyModule guardian from deployer EOA to an ops multisig
