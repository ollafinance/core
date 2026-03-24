#!/usr/bin/env bash

set -euo pipefail
shopt -s globstar nullglob

include_tests=1
for arg in "$@"; do
  case "$arg" in
    --no-tests)
      include_tests=0
      ;;
  esac
done

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

patterns=(src/**/*.sol script/**/*.sol)
if (( include_tests )); then
  patterns+=(test/**/*.sol)
fi

for f in "${patterns[@]}"; do
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
