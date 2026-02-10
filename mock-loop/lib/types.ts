// Scenario configuration types
export interface ProviderKeysScenario {
  type: "provider-keys";
  enabled: boolean;
  every?: number;
  at?: number;
  minKeys: number;
  seedCount: number;
}

export interface MockRewardsScenario {
  type: "mock-rewards";
  enabled: boolean;
  every?: number;
  at?: number;
  rate: string; // BigInt as string
}

export interface UserDepositScenario {
  type: "user-deposit";
  enabled: boolean;
  every?: number;
  at?: number;
  amount: string; // BigInt as string
  privateKey: string;
}

export interface RebalanceScenario {
  type: "rebalance";
  enabled: boolean;
  every?: number;
  at?: number;
  maxIterations?: number;
}

export interface AccountingScenario {
  type: "accounting";
  enabled: boolean;
  every?: number;
  at?: number;
}

export interface UserInitiateWithdrawScenario {
  type: "user-initiate-withdraw";
  enabled: boolean;
  every?: number;
  at?: number;
  privateKey: string;
}

export interface UserClaimScenario {
  type: "user-claim";
  enabled: boolean;
  every?: number;
  at?: number;
  privateKey: string;
}

export type ScenarioConfig =
  | ProviderKeysScenario
  | MockRewardsScenario
  | UserDepositScenario
  | RebalanceScenario
  | AccountingScenario
  | UserInitiateWithdrawScenario
  | UserClaimScenario;

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
  config?: string;
}
