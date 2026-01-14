# Soldeer Migration Plan

## Status: COMPLETED

All tasks completed successfully:
- `forge soldeer install` - Works
- `forge build` - Compiles successfully (67 files)
- `forge test` - 24/25 tests pass (1 pre-existing test bug unrelated to Soldeer)

---

## Problem

The OpenZeppelin Upgradeable package (`@openzeppelin-contracts-upgradeable-5.5.0-rc.1`) references its base contracts using imports like:

```solidity
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
```

However, the current remappings map `@openzeppelin/` to `dependencies/@openzeppelin-contracts-5.5.0-rc.1/`, which lacks a `contracts/` subfolder - the Solidity files are directly in the root.

**What's needed:** A remapping for `@openzeppelin/contracts/` → `dependencies/@openzeppelin-contracts-5.5.0-rc.1/` (without `contracts/` in the target path).

## Tasks

### Step 1: Update `remappings.txt`

Replace with a clean, deduplicated set of remappings that:
- Keeps short aliases (`@oz/`, `@oz-upgradeable/`, `@az/`, `@forge-std/`)
- Adds the mappings OpenZeppelin's internal imports expect (`@openzeppelin/contracts/`, `@openzeppelin/contracts-upgradeable/`)

**New `contracts/remappings.txt`:**
```
# Short aliases for project imports
@oz/=dependencies/@openzeppelin-contracts-5.5.0-rc.1/
@oz-upgradeable/=dependencies/@openzeppelin-contracts-upgradeable-5.5.0-rc.1/
@az/=dependencies/aztec-contracts-3.0.1/src/
@forge-std/=dependencies/forge-std-1.11.0/src/

# Required for OpenZeppelin internal imports
@openzeppelin/contracts/=dependencies/@openzeppelin-contracts-5.5.0-rc.1/
@openzeppelin/contracts-upgradeable/=dependencies/@openzeppelin-contracts-upgradeable-5.5.0-rc.1/
```

### Step 2: Add `[soldeer]` section to `foundry.toml`

Disable auto-generation of remappings so Soldeer doesn't overwrite manual configuration:

```toml
[soldeer]
remappings_generate = false
```

### Step 3: Remove `foundry.lock`

Delete the unused `foundry.lock` file (Soldeer uses `soldeer.lock` instead).

### Step 4: Verify everything works

```bash
cd contracts
forge clean
forge soldeer install
forge build
forge test
```

## Expected Outcome

- `forge soldeer install` - Downloads dependencies to `dependencies/`
- `forge build` - Compiles all contracts successfully
- `forge test` - All tests pass

## Actual Outcome

All Soldeer-related tasks completed successfully:

- `forge soldeer install` - Works correctly
- `forge build` - Compiles 67 files successfully
- `forge test` - 24/25 tests pass

### Pre-existing Test Issue (Unrelated to Soldeer)

One fuzz test fails: `testFuzz_RevertWhen_UnauthorizedRedeem`

The test expects `OllaCoreUnauthorized` error, but when the fuzz test generates `receiver = address(0)`, the contract reverts with `OllaCoreZeroAddress` first (checked before authorization). This is a test bug, not a Soldeer issue - the test should exclude `address(0)` from the fuzz inputs or handle both error cases.
