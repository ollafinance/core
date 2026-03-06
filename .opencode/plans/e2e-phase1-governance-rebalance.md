# Phase 1: Governance Parameter Changes During Rebalance

**Risk**: Critical — parameter changes during the multi-step rebalance state machine could corrupt accounting or alter fee/buffer behavior mid-cycle.

## Scope

Validate that:
- The `whenRebalanceDone` modifier on OllaCore parameter setters blocks governance execution during an active rebalance
- Parameter changes between cycles correctly affect the next rebalance
- Fee split and buffer target changes are reflected in subsequent fee payouts and staking behavior

## Prerequisites

- OllaGovernance deployed with TimelockController (real, proxied)
- OllaCore, OllaVault, WithdrawalQueue, StAztec (real, proxied)
- MockAccountingStakingManager (to control staking behavior and gas burning)
- SafetyModule (real)
- RewardsAccumulator (real mock — accepts/releases tokens)

## Implementation Steps

### 1. Create test contract with full governance stack

Follow the pattern from `OllaGovernanceSetup.t.sol` but wire in a real SafetyModule and WithdrawalQueue instead of mocks.

```solidity
// contracts/test/e2e/GovernanceRebalanceInteraction.e2e.t.sol

contract GovernanceRebalanceInteractionE2ETest is Test {
    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant DECIMALS = 1e18;

    OllaGovernance internal gov;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    WithdrawalQueue internal withdrawalQueue;
    SafetyModule internal safetyModule;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockAztec internal asset;

    address internal admin;
    address internal guardian;
    address internal operator;
    address internal user;
    address internal treasury;
    address internal providerRewards;
}
```

### 2. Setup with governance as owner

```solidity
function setUp() external {
    // Deploy OllaGovernance with timelock
    // Deploy all contracts with OllaGovernance as owner
    // Wire: core.setVault(), gov.setCore()
    // Grant roles, unpause
    // Set initial: protocolFeeBP = 500, treasuryFeeSplitBP = 5000
}
```

### 3. Helper to force rebalance to stop mid-cycle

Use `MockAccountingStakingManager.setGasBurnTarget()` to consume gas during `getUnstakedFunds()`, causing the rebalance to stop at the `PullUnstaked` step due to the gas threshold check.

```solidity
function _forceRebalanceMidCycle() internal {
    // Set gas burn target high enough that rebalance runs out of gas after PullUnstaked
    stakingManager.setGasBurnTarget(200_000);
    vm.prank(operator);
    core.rebalance();
    // Assert we stopped at an intermediate step
    IOllaCore.RebalanceProgress memory p = core.rebalanceProgress();
    assertTrue(uint256(p.step) != uint256(IOllaCore.RebalanceStep.Done));
}
```

### 4. Governance scheduling helper

```solidity
function _scheduleAndExecute(address target, bytes memory data) internal {
    vm.prank(admin);
    gov.schedule(target, 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    vm.warp(block.timestamp + MIN_DELAY);
    vm.prank(admin);
    gov.execute(target, 0, data, bytes32(0), bytes32(0));
}
```

## Test Cases

### Test 1a: `test_GovernanceCannotChangeFeeDuringRebalance`

```
Setup:
  1. alice deposits 100e18
  2. Set targetBufferedAssets = 0 (force staking)
  3. Warp past cooldown
  4. Force rebalance to stop mid-cycle via gas burning

Actions:
  5. Schedule governance: gov.setProtocolFeeBP(1000)
  6. Warp past timelock delay
  7. Execute governance action

Assertions:
  - rebalanceProgress().step != Done (precondition)
  - Execute reverts — the setProtocolFeeBP call on Core hits whenRebalanceDone guard
  - protocolFeeBP unchanged (still 500)
```

### Test 1b: `test_GovernanceCanChangeFeeBetweenRebalanceCycles`

```
Setup:
  1. alice deposits 100e18
  2. Full rebalance cycle (completes to Done)

Actions:
  3. Schedule + execute: gov.setProtocolFeeBP(1000)
  4. Simulate 10e18 rewards via MockAccountingStakingManager.setHarvestedRewards(10e18)
  5. Full rebalance with rewards

Assertions:
  - protocolFeeBP == 1000 after governance execution
  - OllaProtocolFeesPaid event: feeAssets = 10e18 * 10% = 1e18
  - stAztec.balanceOf(treasury) > 0 (got treasury share of 1e18 in shares)
  - stAztec.balanceOf(providerRewards) > 0 (got provider share)
```

### Test 1c: `test_GovernanceSetTargetBufferBetweenCycles_AffectsNextRebalance`

```
Setup:
  1. alice deposits 200e18
  2. targetBufferedAssets = 10e18
  3. Full rebalance → stakes ~190e18, buffer ~10e18

Actions:
  4. Schedule + execute: gov.setTargetBufferedAssets(100e18) via core passthrough
  5. Mock 40e18 unstaked funds available
  6. Full rebalance

Assertions:
  - After step 3: vault buffer ~10e18, stakedPrincipal ~190e18
  - After step 6: rebalance initiated unstake to bring buffer toward 100e18
  - unstake was called on StakingManager
  - Rebalance completes to Done
```

### Test 1d: `test_GovernanceTreasuryFeeSplitChange_AffectsDistribution`

```
Setup:
  1. alice deposits 100e18
  2. protocolFeeBP = 1000 (10%), treasuryFeeSplitBP = 5000 (50/50)
  3. Simulate 10e18 rewards, full rebalance
  4. Record: treasuryBal1 = stAztec.balanceOf(treasury)
  5. Record: providerBal1 = stAztec.balanceOf(providerRewards)

Actions:
  6. Schedule + execute: gov.setTreasuryFeeSplitBP(9000) (90/10)
  7. Simulate another 10e18 rewards, full rebalance

Assertions:
  - Cycle 1: treasuryBal1 ~= providerBal1 (50/50 split)
  - Cycle 2: (treasury new - treasuryBal1) ~= 9 * (provider new - providerBal1) (90/10 split)
  - Total fee shares per cycle match 10% of gross rewards converted to shares
```

## Acceptance Criteria

- [ ] `whenRebalanceDone` guard prevents ALL governance parameter changes during active rebalance
- [ ] Parameter changes via OllaGovernance timelock are correctly applied between cycles
- [ ] Changed parameters (fee, split, buffer target) affect the immediately-next rebalance cycle
- [ ] No accounting corruption from governance timing interactions
- [ ] Events emitted with correct values after parameter changes

## Verification

```bash
forge test --match-contract GovernanceRebalanceInteractionE2ETest -vvv
```
