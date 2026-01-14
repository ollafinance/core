# Solhint Rules

This package contains custom Solhint rules used by the Olla Core repo.

## Explicit Return Rule

- **Rule name**: `explicit-return/explicit-return`
- **Purpose**: Enforces explicit `return` statements when a function uses named return variables.

## Build

Build the rule output after changes:

```bash
yarn solhint:build
```

The build emits to `solhint-rules/dist` and is used by Solhint via the plugin entry.

## Lint

```bash
yarn lint
```

## Local Development Notes

- The plugin is linked via `portal:./solhint-rules`, so rebuilding is enough to pick up changes.
- If you add new rules, export them in `solhint-rules/index.ts` and update tests under `solhint-rules/__tests__/`.
