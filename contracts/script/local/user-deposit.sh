#!/usr/bin/env bash
set -euo pipefail

RPC_URL=${RPC_URL:-http://127.0.0.1:8545}
USER_KEY=${USER_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
USER_ADDRESS=${USER_ADDRESS:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}
ASSET_ADDRESS=${ASSET_ADDRESS:-0x7a9ec1d04904907de0ed7b6839ccdd59c3716ac9}
CORE_ADDRESS=${CORE_ADDRESS:-0x4c2f7092c2ae51d986befee378e50bd4db99c901}
AMOUNT_WEI=${AMOUNT_WEI:-1000000000000000000}

VAULT_ADDRESS=$(cast call "$CORE_ADDRESS" "vault()(address)" --rpc-url "$RPC_URL")

cast send --rpc-url "$RPC_URL" --private-key "$USER_KEY" "$ASSET_ADDRESS" \
  "mint(address,uint256)" "$USER_ADDRESS" "$AMOUNT_WEI"

cast send --rpc-url "$RPC_URL" --private-key "$USER_KEY" "$ASSET_ADDRESS" \
  "approve(address,uint256)" "$VAULT_ADDRESS" "$AMOUNT_WEI"

cast send --rpc-url "$RPC_URL" --private-key "$USER_KEY" "$VAULT_ADDRESS" \
  "deposit(uint256,address,uint256)" "$AMOUNT_WEI" "$USER_ADDRESS" 0
