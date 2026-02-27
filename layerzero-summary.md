# LayerZero Bridge Integration

## What was added

This branch adds cross-chain bridging for stAztec using [LayerZero V2](https://docs.layerzero.network/v2). It allows stAztec holders on Ethereum (the home chain) to bridge their tokens to any supported destination chain (and back).

### New contracts

- **`StAztecOFTAdapter`** (`contracts/src/bridge/StAztecOFTAdapter.sol`) — Deployed on Ethereum (home chain). Inherits LayerZero's `OFTAdapter`, which locks stAztec tokens in the adapter when bridging out and unlocks them when bridging back. This is the single entry/exit point for stAztec cross-chain transfers on the home chain.

- **`StAztecOFT`** (`contracts/src/bridge/StAztecOFT.sol`) — Deployed on each destination chain. Inherits LayerZero's `OFT`, which mints a bridged stAztec representation when tokens arrive from the home chain and burns them when sent back. Each destination chain gets its own independent `StAztecOFT` deployment.

### Deploy scripts

- **`StAztecOFTAdapterDeployer`** (`contracts/script/deployers/StAztecOFTAdapter.s.sol`) — Deployer for the home-chain adapter.
- **`Deploy.s.sol`** updated to deploy the adapter as part of the standard deployment flow (step 4a). For local dev, a mock LayerZero endpoint is deployed first.

### Tests

- **`StAztecOFTAdapter.t.sol`** (`contracts/test/bridge/StAztecOFTAdapter.t.sol`) — Full test suite covering:
  - Constructor validation for both adapter and OFT
  - Bridge home → destination (lock + mint)
  - Bridge destination → home (burn + unlock)
  - Full round trip
  - Fee quoting
  - Access control (`setPeer` owner-only)
  - Edge cases (zero amount, insufficient balance, missing approval)

### Dependencies

LayerZero V2 Solidity packages were added via soldeer:
- `@layerzerolabs/oft-evm` (v4.0.1) — OFT and OFTAdapter contracts
- `@layerzerolabs/oapp-evm` (v0.4.1) — OApp base, OptionsBuilder, test helpers
- `@layerzerolabs/lz-evm-protocol-v2` (v3.0.160) — EndpointV2
- `@layerzerolabs/lz-evm-messagelib-v2` (v3.0.160) — ULN message libraries
- `@layerzerolabs/lz-evm-v1-0-7` (v3.0.160) — V1 compatibility layer (required by test helpers)
- `solidity-bytes-utils` (v0.8.2) — Required by LayerZero test helpers

## Why OFTAdapter (lock/unlock) and not OFT (burn/mint)

LayerZero offers two patterns for bridging an existing ERC-20:

| | OFTAdapter (lock/unlock) | MintBurnOFTAdapter (burn/mint) |
|---|---|---|
| **Mechanism** | Locks tokens in adapter on send; unlocks on receive | Burns tokens on send; mints on receive |
| **Requires minting rights** | No — only needs ERC-20 `transferFrom` | Yes — adapter must be able to `mint()` and `burn()` on the token |

We use **OFTAdapter** because:

1. **StAztec has a single immutable minter.** `StAztec.sol` has `address public immutable OLLA_CORE` — only OllaCore can call `mint()` and `burn()`. Granting mint rights to a bridge adapter would require adding `AccessControl` or a similar role system to StAztec, which adds complexity and attack surface to a core protocol contract for a peripheral feature.

2. **No exchange rate impact.** OllaCore computes `exchangeRate = totalAssets / stAztec.totalSupply()`. With lock/unlock, bridged tokens remain in existence (held by the adapter), so `totalSupply()` is unchanged and the exchange rate is unaffected. A burn/mint approach would reduce `totalSupply()` when tokens are bridged out, causing the exchange rate to drift upward for remaining home-chain holders — a subtle but unnecessary complication.

3. **Single home chain.** LayerZero requires exactly one `OFTAdapter` per global OFT mesh, which would be a limitation if stAztec needed to be natively bridgeable from multiple source chains. Since Ethereum L1 is the only home chain, this constraint is irrelevant.

4. **Simplicity.** The adapter is a thin wrapper (~25 lines) with no custom logic. It inherits battle-tested LayerZero code and requires no changes to existing core contracts.

## Destination chain deployments

Deploying `StAztecOFT` on additional destination chains is **opt-in and can be done after the fact**. The process for each new chain:

1. Deploy `StAztecOFT` on the destination chain with the local LayerZero endpoint
2. Call `setPeer()` on the new `StAztecOFT` to register the home-chain adapter
3. Call `setPeer()` on the home-chain `StAztecOFTAdapter` to register the new destination
4. Configure DVN/executor settings as needed

No redeployment or upgrade of the home-chain adapter is required. Each destination chain operates independently — adding or removing a chain has no effect on other chains or the core protocol.
