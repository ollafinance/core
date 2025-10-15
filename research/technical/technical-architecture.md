# Technical Architecture

## Overview

Comprehensive technical architecture of the Olla liquid staking protocol, showing the interaction between on-chain contracts, off-chain components, and external integrations.

## System Architecture

```mermaid
graph TB
    subgraph "User Interface Layer"
        A[Frontend DApp] --> B[Web3 Wallet Integration]
        C[Mobile Apps] --> B
        D[Integration SDKs] --> B
    end
    
    subgraph "On-Chain Core Protocol"
        E[Liquid Staking Pool] --> F[oAztec ERC-20 Token]
        E --> G[DelegationRouter]
        G --> H[OperatorRegistry]
        
        I[RewardsCollector] --> E
        J[WithdrawalBuffer] --> E
        K[ParameterRegistry] --> E
        
        L[PerformanceOracle] --> H
        M[PriceOracle] --> N[RateAdapter]
        N --> O[External DeFi Protocols]
    end
    
    subgraph "Governance Layer"
        P[Olla DAO] --> Q[Governor Contract]
        Q --> R[Timelock Controller]
        R --> K
        S[Guardian] --> T[Emergency Pause]
    end
    
    subgraph "Off-Chain Infrastructure"
        U[Oracle Network] --> L
        U --> M
        V[Monitoring Systems] --> W[Performance Tracking]
        X[Frontend Backend] --> Y[Analytics API]
    end
    
    subgraph "External Dependencies"
        Z[Aztec Network] --> AA[Validator Nodes]
        AA --> G
        BB[DeFi Ecosystem] --> F
        CC[Price Feeds] --> U
        DD[Node Operators] --> AA
    end
    
    B --> E
    F --> BB
    W --> H
    T --> E
    
    style E fill:#e1f5fe
    style F fill:#e8f5e8
    style P fill:#fff3e0
    style U fill:#f3e5f5
```

## Core Contract Architecture

### Liquid Staking Pool (Core Contract)

**Role**: Central hub for all staking operations

```solidity
contract LiquidStakingPool is ERC7540, AccessControl, Pausable {
    // Core state variables
    uint256 public totalAssets;           // Total Aztec tokens under management
    uint256 public totalShares;          // Total oAztec shares issued
    uint256 public exchangeRate;         // Current oAztec/Aztec rate
    
    // Contract dependencies
    IOAztecToken public oAztecToken;      // Liquid staking token
    IDelegationRouter public delegationRouter;  // Validator delegation
    IRewardsCollector public rewardsCollector;  // Reward management
    IWithdrawalBuffer public withdrawalBuffer;  // Liquidity management
    
    // Core functions
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function requestWithdraw(uint256 assets, address receiver) external returns (uint256 requestId);
    function claimWithdraw(address receiver) external returns (uint256 assets);
}
```

### Contract Relationships

```mermaid
classDiagram
    LiquidStakingPool --> OAztecToken : mints/burns
    LiquidStakingPool --> DelegationRouter : delegates stake
    LiquidStakingPool --> RewardsCollector : collects rewards
    LiquidStakingPool --> WithdrawalBuffer : manages liquidity

    DelegationRouter --> OperatorRegistry : queries operators
    OperatorRegistry --> PerformanceOracle : receives performance data

    Governor --> ParameterRegistry : updates parameters
    ParameterRegistry --> LiquidStakingPool : provides configuration

    Guardian --> LiquidStakingPool : emergency pause
    
    class LiquidStakingPool {
        +deposit()
        +withdraw()
        +requestWithdraw()
        +claimWithdraw()
    }
    
    class OAztecToken {
        +mint()
        +burn()
        +transfer()
        +permit()
    }
    
    class DelegationRouter {
        +delegateToOperator()
        +undelegateFromOperator()
        +rebalance()
    }
```

## Token Architecture

### oAztec Token Implementation

```solidity
contract OAztecToken is ERC20, ERC20Permit, ERC1271, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    ILiquidStakingPool public stakingPool;
    IRateAdapter public rateAdapter;
    
    // ERC-20 with yield-bearing semantics
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account); // Returns shares, not underlying value
    }
    
    // Convenience functions for underlying value
    function balanceOfUnderlying(address account) public view returns (uint256) {
        return rateAdapter.convertToAssets(balanceOf(account));
    }
    
    // ERC-2612 permit functionality
    function permit(
        address owner, address spender, uint256 value,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) public override {
        // Standard permit implementation
    }
    
    // ERC-1271 for smart contract wallets
    function isValidSignature(bytes32 hash, bytes memory signature) 
        public view returns (bytes4) {
        // Smart wallet signature validation
    }
}
```

## Oracle Architecture

### Performance Oracle Network

```mermaid
graph LR
    subgraph "Data Sources"
        A[Aztec Network RPC]
        B[Block Explorers] 
        C[Validator APIs]
    end
    
    subgraph "Oracle Nodes"
        D[Oracle Node 1]
        E[Oracle Node 2] 
        F[Oracle Node 3]
    end
    
    subgraph "Consensus Layer"
        G[Multi-Signature Validation]
        H[Checkpoint Aggregation]
    end
    
    subgraph "On-Chain Oracle"
        I[PerformanceOracle Contract]
        J[Historical Data Storage]
    end
    
    A --> D
    B --> E
    C --> F
    
    D --> G
    E --> G
    F --> G
    
    G --> H
    H --> I
    I --> J
```

### Oracle Contract Structure

```solidity
contract PerformanceOracle is AccessControl {
    struct ValidatorMetrics {
        uint256 uptime;              // Basis points (0-10000)
        uint256 rewardEfficiency;   // Basis points vs network average
        uint256 slashingEvents;     // Count of slashing incidents
        uint256 lastUpdate;        // Timestamp of last update
    }
    
    struct Checkpoint {
        bytes32 metricsHash;        // Hash of performance data
        uint256 timestamp;          // When checkpoint was created
        address[] signers;          // Oracle signers
        bytes[] signatures;         // Cryptographic proofs
        bool finalized;            // Whether checkpoint is accepted
    }
    
    mapping(address => ValidatorMetrics) public validatorMetrics;
    mapping(uint256 => Checkpoint) public checkpoints;
    mapping(address => bool) public authorizedSigners;
    
    uint256 public requiredSignatures = 3;
    uint256 public checkpointInterval = 3600; // 1 hour
    
    function submitCheckpoint(
        bytes32 metricsHash,
        address[] memory signers,
        bytes[] memory signatures
    ) external {
        require(signers.length >= requiredSignatures, "Insufficient signatures");
        
        // Validate signatures and update metrics
        validateAndUpdateMetrics(metricsHash, signers, signatures);
    }
}
```

## Delegation Architecture

### Multi-Operator Delegation System

```solidity
contract DelegationRouter is AccessControl {
    struct DelegationTarget {
        address operator;           // Validator operator address
        uint256 currentStake;      // Currently delegated amount
        uint256 targetStake;       // Desired delegation amount
        uint256 lastRebalance;     // Last rebalancing timestamp
    }
    
    mapping(address => DelegationTarget) public delegations;
    address[] public activeOperators;
    
    IOperatorRegistry public operatorRegistry;
    IPerformanceOracle public performanceOracle;
    
    function calculateOptimalAllocation() public view returns (uint256[] memory) {
        uint256[] memory weights = new uint256[](activeOperators.length);
        
        for (uint i = 0; i < activeOperators.length; i++) {
            address operator = activeOperators[i];
            
            // Get performance score
            uint256 performance = performanceOracle.getPerformanceScore(operator);
            
            // Get available capacity
            uint256 capacity = operatorRegistry.getAvailableCapacity(operator);
            
            // Calculate weight based on performance and capacity
            weights[i] = performance * capacity / 1e18;
        }
        
        return normalizeWeights(weights);
    }
    
    function rebalance() external onlyRole(REBALANCER_ROLE) {
        uint256[] memory targetAllocations = calculateOptimalAllocation();
        
        // Execute stake movements
        for (uint i = 0; i < activeOperators.length; i++) {
            address operator = activeOperators[i];
            uint256 currentStake = delegations[operator].currentStake;
            uint256 targetStake = targetAllocations[i];
            
            if (targetStake != currentStake) {
                executeStakeMovement(operator, currentStake, targetStake);
            }
        }
    }
}
```

## Governance Architecture

### DAO Governance Structure

```mermaid
graph TD
    A[Token Holders] --> B[Create Proposal]
    B --> C[Governor Contract]
    C --> D[Voting Period]
    D --> E{Vote Passes?}
    E -->|Yes| F[Timelock Queue]
    E -->|No| G[Proposal Rejected]
    F --> H[Execution Delay]
    H --> I[Execute Proposal]
    I --> J[Parameter Update]
    
    K[Emergency Guardian] --> L[Immediate Pause]
    L --> M[DAO Review]
    M --> N[Recovery Action]
    
    style C fill:#e1f5fe
    style K fill:#ffcdd2
```

### Governance Contracts

```solidity
contract OllaGovernor is 
    Governor,
    GovernorSettings,
    GovernorCountingSimple, 
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl 
{
    constructor(
        IVotes _token,
        TimelockController _timelock
    ) 
        Governor("OllaGovernor")
        GovernorSettings(7200, 50400, 0) // 1 day delay, 1 week voting, 0 threshold
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4) // 4% quorum
        GovernorTimelockControl(_timelock)
    {}
    
    // Override required functions
    function quorum(uint256 blockNumber) public view override returns (uint256) {
        return super.quorum(blockNumber);
    }
    
    function proposalThreshold() public view override returns (uint256) {
        return super.proposalThreshold();
    }
}
```

## Security Architecture

### Multi-Layer Security Model

```mermaid
graph TB
    subgraph "Access Control Layer"
        A[Role-Based Permissions]
        B[Multi-Signature Requirements]
        C[Timelock Controls]
    end
    
    subgraph "Contract Security Layer"
        D[Reentrancy Guards]
        E[Overflow Protection]
        F[Input Validation]
        G[State Consistency Checks]
    end
    
    subgraph "Economic Security Layer"
        H[Slashing Protection]
        I[Insurance Mechanisms]
        J[Circuit Breakers]
        K[Rate Limiting]
    end
    
    subgraph "Operational Security Layer"
        L[Emergency Pause]
        M[Guardian Powers]
        N[Incident Response]
        O[Recovery Procedures]
    end
    
    A --> D
    B --> E
    C --> F
    D --> H
    E --> I
    F --> J
    G --> K
    H --> L
    I --> M
    J --> N
    K --> O
```

### Emergency Systems

```solidity
contract EmergencySystem is AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    bool public emergencyPaused = false;
    uint256 public pausedAt;
    uint256 public constant MAX_PAUSE_DURATION = 7 days;
    
    event EmergencyPause(address guardian, string reason);
    event EmergencyUnpause(address authority);
    
    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "Not guardian");
        _;
    }
    
    modifier whenNotEmergencyPaused() {
        require(!emergencyPaused, "Emergency paused");
        _;
    }
    
    function emergencyPause(string calldata reason) external onlyGuardian {
        require(!emergencyPaused, "Already paused");
        
        emergencyPaused = true;
        pausedAt = block.timestamp;
        
        emit EmergencyPause(msg.sender, reason);
        
        // Pause all main operations
        _pauseStakingPool();
        _pauseWithdrawals();
        _pauseRebalancing();
    }
    
    function emergencyUnpause() external {
        require(emergencyPaused, "Not paused");
        require(
            hasRole(EMERGENCY_ROLE, msg.sender) || 
            block.timestamp > pausedAt + MAX_PAUSE_DURATION,
            "Unauthorized unpause"
        );
        
        emergencyPaused = false;
        pausedAt = 0;
        
        emit EmergencyUnpause(msg.sender);
        
        // Resume operations
        _unpauseStakingPool();
        _unpauseWithdrawals(); 
        _unpauseRebalancing();
    }
}
```

## Integration Architecture

### DeFi Integration Points

```mermaid
graph LR
    subgraph "Olla Protocol"
        A[oAztec Token]
        B[Rate Adapter]
    end
    
    subgraph "DeFi Protocols"
        C[AMM Pools]
        D[Lending Protocols]
        E[Yield Farms]
        F[Derivatives]
    end
    
    subgraph "Integration Layer"
        G[Price Feeds]
        H[Liquidity Adapters]
        I[Vault Interfaces]
    end
    
    A --> G
    B --> H
    B --> I
    
    G --> C
    H --> D
    I --> E
    
    C --> F
    D --> F
    E --> F
```

### Rate Adapter for Integrations

```solidity
interface IRateAdapter {
    // Core rate information
    function getExchangeRate() external view returns (uint256);
    function getLatestUpdate() external view returns (uint256);
    
    // Conversion utilities
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    
    // Historical data for analytics
    function getRateAtBlock(uint256 blockNumber) external view returns (uint256);
    function getAverageRate(uint256 periods) external view returns (uint256);
    
    // Integration metadata
    function getTokenInfo() external view returns (
        address token,
        string memory name,
        string memory symbol,
        uint8 decimals
    );
}
```

## Development Architecture

### Deployment Pipeline

```mermaid
graph TD
    A[Development] --> B[Unit Tests]
    B --> C[Integration Tests]
    C --> D[Security Audits]
    D --> E[Testnet Deployment]
    E --> F[Community Testing]
    F --> G[Mainnet Deployment]
    
    H[Monitoring] --> I[Performance Metrics]
    I --> J[Security Monitoring]
    J --> K[Incident Response]
    
    G --> H
```

### Upgrade Architecture

- **Proxy Patterns**: Upgradeable contracts for protocol evolution
- **Version Management**: Semantic versioning and backward compatibility
- **Migration Scripts**: Automated data migration between versions
- **Rollback Procedures**: Emergency rollback capabilities

---

**Tags:** #technical-architecture #smart-contracts #system-design #security #governance #oracles #integration

**Links:**

- [[liquid-staking-mechanics]] - Core protocol implementation
- [[oAztec-token-design]] - Token contract architecture
- [[dao-governance]] - Governance system technical details
- [[oracle-design]] - Oracle network architecture
- [[node-operator-framework]] - Validator integration
- [[risk-assessment]] - Security considerations
- [[emergency-procedures]] - Emergency system architecture

**Last Updated:** 2025-10-15
