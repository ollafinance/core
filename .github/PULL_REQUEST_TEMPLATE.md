## Summary

## Changes

## Testing
- [ ] Unit tests (`forge test --match-path "test/**/*.t.sol" --no-match-path "test/**/*.{integration,invariant}.t.sol"`)
- [ ] Integration tests (`forge test --match-path "test/**/*.integration.t.sol"`)
- [ ] Invariant tests (`forge test --match-path "test/**/*.invariant.t.sol"`)
- [ ] Storage layout (`yarn check:storage` — update fixtures with `yarn check:storage:update` if storage changed)
- [ ] solhint "src/**/*.sol"
- [ ] slither . --config-file slither.config.json

## Checklist
- [ ] Linked issue
- [ ] Docs updated (if needed)
- [ ] Tests added/updated (if needed)
