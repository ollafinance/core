---
description: Run solhint on contracts
agent: smart-contract-dev
---

Run solhint on the Foundry project.
Use `contracts/.solhint.json` and prefer `--fix` when safe.

Commands:

!`yarn exec solhint --config contracts/.solhint.json --fix contracts/src`

If solhint reports issues that cannot be auto-fixed, explain why and propose a minimal patch.
