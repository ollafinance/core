# Olla Core

Olla Core is the Ethereum smart contract layer for the Olla liquid staking protocol on Aztec.
This repository pairs a research vault with a Foundry-based contract workspace, and is structured
to grow into an open-source, auditable codebase.

## Repository layout

- `contracts/` Foundry project for the core contracts.
- `contracts/src/core/` Protocol core contracts.
- `contracts/src/modules/` Reusable modules (pause/roles/etc).
- `contracts/src/interfaces/` External-facing interfaces.
- `contracts/src/libraries/` Shared libraries.
- `contracts/src/mocks/` Test/mocked contracts and fixtures.
- `contracts/script/` Foundry scripts.
- `contracts/test/` Component-based Foundry tests (e.g., `core/`, `modules/`).
- `research/` Protocol research and design notes (Obsidian vault).

Key research index:

- `research/technical/technical-architecture.md`

## Tooling

- Solidity + Foundry for development and testing
- Solhint for Solidity linting (includes a custom rule plugin)
- Slither + Slytherin for static analysis

## Quickstart

From the repo root:

```bash
cd contracts
forge soldeer install
forge build
forge test
```

Invariant-only suite:

```bash
cd contracts
forge test --match-path "test/**/*.invariant.sol"
```

## Linting

```bash
yarn install
yarn lint
```

The custom Solhint rules live in `solhint-rules/` and are built automatically by the lint script. For more details, see `solhint-rules/README.md`.

To enforce linting on every commit, install dependencies to enable Husky hooks:

```bash
yarn install
```

If hooks still don't fire, run:

```bash
yarn husky install
```

## Static analysis

Slither is pinned in CI to `0.11.4` (see `.github/workflows/slither.yml`). To match CI locally:

```bash
python -m pip install -U slither-analyzer==0.11.4
yarn slither
```

Slitherin is pinned in CI to `0.7.2` and patched for Slither 0.11.4 compatibility. To match CI locally:

```bash
python -m pip install -U slitherin==0.7.2
python - <<'PY'
import inspect
import os
import re
import slitherin

path = os.path.join(os.path.dirname(inspect.getfile(slitherin)), "detectors", "nft_approve_warning.py")
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

lines = src.splitlines()
patched = False
for i, line in enumerate(lines):
    if "for f_called in f.library_calls:" in line:
        indent = re.match(r"\s*", line).group(0)
        start = i
        end = i + 1
        while end < len(lines):
            if lines[end].strip() == "":
                end += 1
                continue
            if not lines[end].startswith(indent + "    "):
                break
            end += 1

        new_block = [
            f"{indent}for f_called in f.library_calls:",
            f"{indent}    # Slither >=0.11.4 returns LibraryCall objects",
            f"{indent}    if hasattr(f_called, \"function\") and hasattr(f_called.function, \"solidity_signature\"):",
            f"{indent}        all_library_calls.append(f_called.function.solidity_signature)",
            f"{indent}    elif hasattr(f_called, \"solidity_signature\"):",
            f"{indent}        all_library_calls.append(f_called.solidity_signature)",
            f"{indent}    else:",
            f"{indent}        # Older Slither returns tuples",
            f"{indent}        all_library_calls.append(f_called[1].solidity_signature)",
        ]

        lines = lines[:start] + new_block + lines[end:]
        patched = True
        break

if not patched:
    raise SystemExit("Expected Slitherin library_calls loop not found; check slitherin version.")

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print("Patched", path)
PY
```

Slitherin runs as a Slither plugin, so use the standard command:

```bash
yarn slither
```

## Storage layout checks

Run storage layout checks whenever upgradeable contracts change storage (new variables, reordered fields, or updated inheritance), and before preparing an upgrade or release.

Check the current layout against the fixture:

```bash
node contracts/script/check-storage-layout.ts --contract OllaCore --fixture contracts/upgrade/fixtures/OllaCore.storage.json
```

If the change is intentional, refresh the fixture from the Foundry output:

```bash
cd contracts
forge inspect OllaCore storageLayout > upgrade/fixtures/OllaCore.storage.json
```

## Contributing

See `CONTRIBUTING.md`.

## License

Apache-2.0. See `LICENSE`.
