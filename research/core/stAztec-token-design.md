# stAztec Token Design (V1)

Legacy docs referred to the token as “oAztec”; V1 standardizes on **stAztec**. This is a non-rebasable ERC20 receipt token minted and burned exclusively by `OllaCore`.

## Core properties
- **ERC20 Standard** with EIP-2612 permit for gasless approvals.
- **Non-rebasable**: Supply changes only via mint/burn; value accrues through `exchangeRate`.
- **Yield-bearing**: Represents a share of underlying Aztec plus rewards.
- **Transferable**: Fully composable for integrations.
- **Redeemable**: Burned when users request withdrawals; assets paid on claim via `WithdrawalQueue`.

## Mint/burn rules
- Mint on deposit (`OllaCore.deposit`) and when protocol fee shares are created during `updateAccounting()`.
- Burn on withdrawal request (`OllaCore.requestWithdrawal`).
- Roles: `MINTER_ROLE` = `OllaCore`; `BURNER_ROLE` = `OllaCore`; `DEFAULT_ADMIN_ROLE` = guardian multisig.

## Exchange rate and value
- Invariant: `exchangeRate = totalAssets() / stAztec.totalSupply()` (see `invariants.md`).
- `balanceOf` reports shares; underlying value is `balanceOf * exchangeRate`.
- First deposit bootstraps `exchangeRate = 1e18`.

## Interfaces
- `mint(address to, uint256 amount)` — only `MINTER_ROLE`.
- `burn(address from, uint256 amount)` — only `BURNER_ROLE`.
- `permit(...)` — EIP-2612.
- Standard ERC20 views and transfers.

## Integration notes
- No rebasing simplifies AMM and lending integrations; pricing should use the on-chain `exchangeRate` from OllaCore.
- Fee shares minted to treasury and node-operator addresses are standard ERC20 mints (no rebasing side effects).
- For DeFi, expose an adapter or view function to convert shares to assets for UI/liquidations.

## References
- Architecture components: `research/technical/architecture/components/staztec.md`
- Interfaces and roles: `research/technical/architecture/interfaces-and-roles.md`
- Accounting and invariants: `research/technical/architecture/invariants.md`
