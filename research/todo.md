# Olla Research Plan

## Overview
Research plan for Olla - the liquid staking protocol for Aztec network. This document tracks progress on various research areas needed to understand and develop the protocol.

## Research Areas

### Core Protocol Research
- [ ] **Liquid Staking Mechanics** - Deep dive into staking pool operations #liquid-staking #protocol-mechanics
- [ ] **oAztec Token Design** - Analysis of the liquid staking token #tokenomics #erc-standards
- [ ] **Validator Delegation Strategy** - How delegation router works #validator-management #delegation
- [ ] **Reward Distribution System** - Compounding and reward tracking mechanisms #rewards #compounding

### Governance & DAO Research  
- [ ] **Olla DAO Structure** - Governance framework and decision making #governance #dao
- [ ] **Parameter Management** - Key protocol parameters and controls #parameters #risk-management
- [ ] **Voting Mechanisms** - ERC20Votes and Governor patterns #voting #governance

### Technical Architecture
- [ ] **ERC Standards Analysis** - All relevant ERC standards used #erc-standards #technical-specs
- [ ] **Smart Contract Architecture** - Contract interactions and dependencies #smart-contracts #architecture
- [ ] **Oracle Design** - Performance and price oracle requirements #oracle-design #off-chain
- [ ] **Security Model** - Slashing, insurance, and risk mitigation #security #risk-management

### Development & Implementation
- [ ] **Phase Development Analysis** - Breakdown of each development phase #mvp-development #roadmap
- [ ] **Integration Possibilities** - DeFi integrations and composability #defi-integration #composability
- [ ] **Competitive Analysis** - Comparison with other liquid staking protocols #market-analysis #competition

### Risk & Operations
- [ ] **Risk Assessment** - Comprehensive risk analysis #risk-management #security
- [ ] **Node Operator Framework** - Selection, monitoring, and management #node-operators #validator-management
- [ ] **Emergency Procedures** - Guardian pause and incident response #emergency #governance

## Architecture Clarifications

### Token Architecture
- **oAztec Token**: ERC-20 token representing shares in the liquid staking pool
- **ERC-7540 Vault**: The underlying vault contract that holds Aztec tokens and implements async deposit/redemption
- **Rate Adapter**: Interface for external protocols to read oAztec exchange rates
- **Relationship**: oAztec tokens are minted/burned by the ERC-7540 vault as users deposit/withdraw

### Core Components Technical Details

#### RewardsCollector
- **Function**: Handles periodic reward collection from validators and updates exchange rates
- **Mechanism**: Automatically compounds rewards by reinvesting them into the pool
- **Integration**: Links to PerformanceOracle for validator performance data
- **Updates**: Triggers exchange rate recalculation when rewards are collected

#### WithdrawalBuffer
- **Purpose**: Maintains liquid Aztec reserves for immediate withdrawals
- **Management**: Queue logic handles larger redemptions that require unstaking
- **Target**: Maintains minimum buffer size to handle 95%+ of withdrawal requests instantly
- **Integration**: Works with ERC-7540 async redemption system

#### DelegationRouter
- **Strategy**: Multi-operator delegation with performance-based allocation
- **Rebalancing**: Automated rebalancing based on operator performance and capacity
- **Integration**: Uses OperatorRegistry for operator management and PerformanceOracle for metrics
- **Algorithm**: Calculates optimal allocation weights based on performance scores and available capacity

#### PerformanceOracle
- **Architecture**: Multi-signer oracle network with consensus mechanism
- **Data Sources**: Aztec network RPC, block explorers, validator APIs
- **Consensus**: Requires multiple signatures (3+ signers) for checkpoint finalization
- **Metrics**: Tracks uptime, reward efficiency, slashing events, and performance scores

### ERC Standards Implementation

#### ERC-20 (oAztec Token)
- **Purpose**: Standard token interface for oAztec shares
- **Implementation**: Non-rebasing shares where value increases via exchange rate
- **DeFi Integration**: Enables standard DeFi protocol interactions

#### ERC-2612 (Permit)
- **Purpose**: Gasless approvals via off-chain signatures
- **Implementation**: EIP-2612 permit function for meta-transactions
- **Benefits**: Better UX for DeFi interactions and account abstraction support

#### ERC-1271 (Smart Wallet Support)
- **Purpose**: Enables smart contract wallets to sign messages
- **Implementation**: isValidSignature function for multisig and DAO participation
- **Use Cases**: Multisig wallets, DAO treasuries, smart contract wallets

#### ERC-7540 (Async Vault)
- **Purpose**: Vault standard supporting asynchronous deposit/redemption
- **Implementation**: Two-phase commit system (request → claim) for large operations
- **Benefits**: Handles high demand periods and unstaking delays gracefully

#### ERC20Votes (Governance)
- **Purpose**: Voting power delegation and historical balance tracking
- **Implementation**: OpenZeppelin ERC20Votes for governance token
- **Features**: Vote delegation, snapshot voting, historical balance queries

#### OpenZeppelin Governor
- **Purpose**: On-chain governance execution system
- **Implementation**: Governor + TimelockController for proposal lifecycle
- **Features**: Proposal creation, voting, timelock delays, execution

#### ERC-721 (Node Operator Identity)
- **Purpose**: Represent node operator identity for transparency
- **Implementation**: NFT representing operator profile and metadata
- **Status**: Nice-to-have feature for operator transparency

## Progress Tracking

### ✅ Completed

#### Core Protocol Research
- **Liquid Staking Mechanics** - Core protocol operations and flow #liquid-staking #protocol-mechanics
- **oAztec Token Design** - Liquid staking token architecture #tokenomics #erc-standards
- **Validator Delegation Strategy** - DelegationRouter and operator management #validator-management #delegation
- **Reward Distribution System** - RewardsCollector and compounding mechanics #rewards #compounding

#### Governance & DAO Research  
- **Olla DAO Structure** - Complete governance framework #governance #dao
- **Parameter Management** - ParameterRegistry and control systems #parameters #risk-management
- **Voting Mechanisms** - ERC20Votes and OpenZeppelin Governor implementation #voting #governance

#### Technical Architecture
- **ERC Standards Analysis** - Individual analysis of all ERC standards #erc-standards #technical-specs
  - ERC-20, ERC-2612, ERC-1271, ERC-7540, ERC20Votes, OpenZeppelin Governor, ERC-721
- **Smart Contract Architecture** - Complete system design and interactions #smart-contracts #architecture
- **Oracle Design** - Performance and price oracle systems #oracle-design #off-chain
- **Security Model** - Comprehensive security framework #security #risk-management

#### Development & Implementation
- **Phase Development Analysis** - Detailed 4-phase roadmap breakdown #mvp-development #roadmap
- **Integration Possibilities** - DeFi integration components and patterns #defi-integration #composability

#### Risk & Operations
- **Risk Assessment** - Complete risk analysis across all components #risk-management #security
- **Node Operator Framework** - Operator selection, monitoring, and management #node-operators #validator-management
- **Emergency Procedures** - Guardian system and incident response #emergency #governance

#### Research Organization
- Organized research into logical folder structure (/core, /governance, /technical, /standards, /operations, /development, /integrations)
- Created comprehensive cross-linking between all components
- Split complex analyses into focused individual files
- Established clear documentation standards and tagging system

### 📁 Final Research Structure Complete
All research areas identified in the original plan have been thoroughly analyzed and documented.

---

## Recent Updates

### Technical Clarifications Added (2025-01-27)
- **Token Architecture**: Clarified relationship between oAztec (ERC-20) and ERC-7540 vault
- **Component Details**: Added technical details for RewardsCollector, WithdrawalBuffer, DelegationRouter, PerformanceOracle
- **ERC Standards**: Enhanced technical implementation details for ERC-20, ERC-1271, ERC-7540
- **Architecture**: Improved DelegationRouter with performance-based allocation algorithm
- **Integration**: Clarified how components work together in the overall system

**Tags:** #research-plan #olla #liquid-staking #aztec-network
**Last Updated:** 2025-01-27
