// Scenario configuration types
export type ScenarioShouldRun = (state: any, tick: number) => boolean;

export interface ProviderKeysScenario {
  type: "provider-keys";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  minKeys: number;
  seedCount: number;
}

export interface RefillKeysScenario {
  type: "refill-keys";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  seedCount: number;
}

export interface MockRewardsScenario {
  type: "mock-rewards";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  rateBps: number;
}

export interface UserDepositScenario {
  type: "user-deposit";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  amount: string; // BigInt as string
  privateKey: string;
}

export interface RebalanceScenario {
  type: "rebalance";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  privateKey?: string; // When set, call rebalance from this wallet instead of operator
}

export interface AccountingScenario {
  type: "accounting";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  privateKey?: string; // When set, call updateAccounting from this wallet instead of operator
}

export interface TimeAdvanceScenario {
  type: "time-advance";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  seconds: number; // Seconds to advance Anvil block time
}

export interface FinalizeExitsScenario {
  type: "finalize-exits";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  privateKey?: string; // When set, call from this wallet instead of operator
}

export interface ExchangeRateCheckScenario {
  type: "exchange-rate-check";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
}

export interface CooldownCheckScenario {
  type: "cooldown-check";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  privateKey?: string; // Wallet to attempt the premature rebalance from
}

export interface UserInitiateWithdrawScenario {
  type: "user-initiate-withdraw";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  privateKey: string;
}

export interface UserClaimScenario {
  type: "user-claim";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  privateKey: string;
}

export interface GovernanceChangeScenario {
  type: "governance-change";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  newGovernancePrivateKey: string;
}

export interface SlashingScenario {
  type: "slashing";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  slashAmountBps: number; // basis points of staked amount to slash
  targetAttesterIndex?: number; // which attester to slash (default: 0)
}

export interface ExternalExitScenario {
  type: "external-exit";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  exitAttesterIndex?: number; // which attester to exit (default: last one)
}

export interface SafetyModuleScenario {
  type: "safety-module";
  enabled: boolean;
  shouldRun?: ScenarioShouldRun;
  action: "configure" | "read-state" | "verify-breaker" | "unpause" | "warp-time";
  warpSeconds?: number; // for warp-time action
  expectedPaused?: boolean; // for verify-breaker: expected isPaused state
}

export type ScenarioConfig =
  | ProviderKeysScenario
  | RefillKeysScenario
  | MockRewardsScenario
  | UserDepositScenario
  | RebalanceScenario
  | AccountingScenario
  | UserInitiateWithdrawScenario
  | UserClaimScenario
  | GovernanceChangeScenario
  | SlashingScenario
  | ExternalExitScenario
  | SafetyModuleScenario
  | TimeAdvanceScenario
  | FinalizeExitsScenario
  | ExchangeRateCheckScenario
  | CooldownCheckScenario;

// Contract state types
export interface AccountingState {
  bufferedAssets: string;
  stakedPrincipal: string;
  rewardsVaultBalance: string;
  claimableRewards: string;
  rewardsDelta: string;
  slashingDelta: string;
  cumulativeRewards: string;
}

export interface StakingState {
  stakedAmount: string;
  pendingUnstakeCount: string;
}

export interface WithdrawalRequest {
  recipient: string;
  finalized: boolean;
  claimed: boolean;
  shares: string;
  assetsExpected: string;
  rate: string;
}

export interface UserState {
  address: string;
  assetBalance: string;
  stAztecBalance: string;
  activeRequestIds: string[];
}

export interface ContractBalances {
  core: string;
  stakingManager: string;
  rollup: string;
  rewardsVault: string;
}

// Full protocol state snapshot
export interface TickState {
  tick: number;
  timestamp: string;
  ollaCore: {
    totalAssets: string;
    exchangeRate: string;
    accountingState: AccountingState;
    flowCounters?: {
      deposits: string;
      withdrawals: string;
    };
  };
  stakingManager: StakingState;
  withdrawalQueue: {
    totalPendingAssets: string;
    nextRequestId: string;
  };
  balances: ContractBalances;
  users: UserState[];
  providerRegistry: {
    availableKeyCount: string;
  };
}

// Action result from scenario execution
export interface ActionResult {
  scenario: string;
  success: boolean;
  txHash?: string;
  error?: string;
  data?: Record<string, unknown>;
}

// Delta between states
export interface StateDelta {
  path: string;
  before: string;
  after: string;
  delta: string;
}

// Full tick result
export interface TickResult {
  tick: number;
  timestamp: string;
  durationMs: number;
  actions: ActionResult[];
  stateBefore: TickState;
  stateAfter: TickState;
  deltas: StateDelta[];
}

// Run configuration
export interface RunConfig {
  rpcUrl: string;
  deployEnv: string;
  intervalMs: number;
  scenarios: ScenarioConfig[];
}

// Deployment addresses
export interface DeploymentAddresses {
  OllaGovernanceImplementation: string;
  OllaGovernanceProxy: string;
  OllaCoreImplementation: string;
  OllaCoreProxy: string;
  Asset: string;
  StAztec: string;
  WithdrawalQueueImplementation: string;
  WithdrawalQueueProxy: string;
  RewardsVaultImplementation: string;
  RewardsVaultProxy: string;
  StakingManagerImplementation: string;
  StakingManagerProxy: string;
  StakingProviderRegistryImplementation: string;
  StakingProviderRegistryProxy: string;
  MockAztecRollup: string;
  MockAztecRollupRegistry: string;
  StakingManager: string;
  SafetyModule: string;
}

export interface DeploymentJson {
  network: string;
  chainId: number;
  deployer: string;
  addresses: DeploymentAddresses;
  stAztecName: string;
  stAztecVersion: string;
}

// CLI arguments
export interface CliArgs {
  once: boolean;
  untilError: boolean;
  config?: string;
}
