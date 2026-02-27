# LayerZero V2 OFT Implementation Plan for stAztec

## Architecture Decision

**OFTAdapter (lock-and-mint)** — the only viable approach because StAztec has an immutable `OLLA_CORE` minter.

- **Home chain (Ethereum):** `StAztecOFTAdapter` locks/unlocks stAztec tokens and sends LayerZero messages.
- **Destination chain(s):** `StAztecOFT` mints/burns bridged stAztec representations.
- **Existing StAztec contract is untouched.**

## Phase 1: Dependencies

Add LayerZero packages as git submodules:

- `@layerzerolabs/oapp-evm` (~v0.4.1)
- `@layerzerolabs/oft-evm` (~v4.0.1)
- `@layerzerolabs/test-devtools-evm-foundry` (~v8.0.1) — test only

Update `contracts/foundry.toml`:
- Add remappings for `@lz-oapp/`, `@lz-oft/`, `@lz-test/`
- Verify compilation with `via_ir = true` and solc 0.8.27

## Phase 2: Contracts

### 2a. `contracts/src/bridge/StAztecOFTAdapter.sol` (Home Chain)
- Inherits `OFTAdapter` from `@layerzerolabs/oft-evm`
- Constructor: `address _stAztec`, `address _lzEndpoint`, `address _delegate`
- Adapter locks/unlocks stAztec via `transferFrom`/`transfer` when bridging
- Owner (delegate) = OllaGovernance TimelockController in production

### 2b. `contracts/src/bridge/StAztecOFT.sol` (Destination Chains)
- Inherits `OFT` from `@layerzerolabs/oft-evm`
- Mints bridged representation of stAztec on destination chain
- Constructor: `name`, `symbol`, `_lzEndpoint`, `_delegate`
- Name: "stAztec", Symbol: "stAZTEC"

### Governance Integration
- The `delegate` (OApp owner) controls peer configuration, DVN settings
- Production: set delegate to OllaGovernance TimelockController
- `setPeer` must be called on both sides for each chain pair

## Phase 3: Tests (Local Foundry)

Using `TestHelperOz5` from LayerZero's test devtools:

### Setup
1. `setUpEndpoints(2, LibraryType.UltraLightNode)` — simulate 2 chains
2. Deploy StAztec + mock OllaCore on chain A
3. Deploy StAztecOFTAdapter on chain A
4. Deploy StAztecOFT on chain B
5. `wireOApps()` to connect peers

### Test Cases
- Bridge stAztec home → destination (lock on A, mint on B)
- Bridge stAztec destination → home (burn on B, unlock on A)
- Quote fees with `quoteSend`
- Access control (only owner can `setPeer`)
- Edge cases: zero amount, insufficient balance, unset peer

### Compatibility Validation
- `via_ir = true` with LZ test helpers
- Solidity 0.8.27 with LZ's `^0.8.22` pragmas
- EVM version `cancun`

## Phase 4: Deployment Scripts (Follow-up / Optional)

For testnet validation (Sepolia + Base Sepolia):
- Deploy script for StAztecOFTAdapter on Sepolia
- Deploy script for StAztecOFT on Base Sepolia
- `setPeer` wiring script
- DVN/Executor configuration
- Optional: `layerzero.config.ts` for LZ tooling

## Key Files

### New Files
- `contracts/src/bridge/StAztecOFTAdapter.sol`
- `contracts/src/bridge/StAztecOFT.sol`
- `contracts/test/unit/bridge/StAztecOFTAdapter.t.sol`

### Modified Files
- `contracts/foundry.toml` — remappings for LZ deps
- `contracts/remappings.txt` — if needed

### Reference
- Example project: `/home/filip/c/z_TEMP/my-lz-oapp/`
- LZ OFT Quickstart: https://docs.layerzero.network/v2/developers/evm/oft/quickstart
- LZ Docs Index: https://docs.layerzero.network/llms.txt
