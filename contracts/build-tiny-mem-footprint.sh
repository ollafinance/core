#!/usr/bin/env bash

set -euo pipefail
shopt -s globstar nullglob

heavy=(
  "src/core/OllaCore.sol"
  "src/vault/OllaVault.sol"
  "src/staking/StakingManager.sol"
  "src/governance/OllaGovernance.sol"
  "script/Deploy.s.sol"
)

files=()

for f in "${heavy[@]}"; do
  [[ -f "$f" ]] || continue
  files+=("$f")
done

for f in src/**/*.sol script/**/*.sol test/**/*.sol; do
  skip=0
  for h in "${heavy[@]}"; do
    if [[ "$f" == "$h" ]]; then
      skip=1
      break
    fi
  done
  (( skip )) && continue
  files+=("$f")
done

total=${#files[@]}
if (( total == 0 )); then
  echo "No Solidity files found to build."
  exit 0
fi

start_ts=$(date +%s)
i=0

for f in "${files[@]}"; do
  i=$((i + 1))
  pct=$((i * 100 / total))
  elapsed=$(( $(date +%s) - start_ts ))
  if (( i <= ${#heavy[@]} )); then
    echo "[$i/$total | ${pct}% | ${elapsed}s] Building heavy: $f"
  else
    echo "[$i/$total | ${pct}% | ${elapsed}s] Building: $f"
  fi
  forge build "$f"
done
