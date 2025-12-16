# ERC20Votes: Voting and Vote Delegation

## Overview
ERC20Votes extends ERC-20 tokens with voting functionality, enabling token holders to participate in governance through direct voting or delegation to trusted representatives. Essential for decentralized governance systems.

## Status
**Implementation**: Post-V1 (governance scope)  
**Priority**: High once governance is introduced  
**Base**: Extension of ERC-20 with checkpoint system

## Interface Definition
```solidity
interface IERC20Votes {
    // Delegation functions
    function delegate(address delegatee) external;
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    
    // Vote power queries
    function getVotes(address account) external view returns (uint256);
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256);
    
    // Delegation queries  
    function delegates(address account) external view returns (address);
    
    // Nonce for delegation signatures
    function nonces(address owner) external view returns (uint256);
    
    // EIP-712 domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    
    // Events
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);
}
```

## Olla Governance Token Implementation

### Core Voting Token
```solidity
contract OllaGovernanceToken is ERC20, ERC20Votes, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    constructor() 
        ERC20("Olla Governance", "OLLA") 
        ERC20Permit("Olla Governance") 
    {}
    
    // Required overrides for multiple inheritance
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }
    
    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }
    
    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }
    
    // Controlled minting for token distribution
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
```

### Checkpoint System
```solidity
abstract contract ERC20Votes is ERC20, ERC20Permit {
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }
    
    mapping(address => address) private _delegates;
    mapping(address => Checkpoint[]) private _checkpoints;
    Checkpoint[] private _totalSupplyCheckpoints;
    
    function _writeCheckpoint(
        Checkpoint[] storage ckpts,
        function(uint256, uint256) view returns (uint256) op,
        uint256 delta
    ) private returns (uint256 oldWeight, uint256 newWeight) {
        uint256 pos = ckpts.length;
        oldWeight = pos == 0 ? 0 : ckpts[pos - 1].votes;
        newWeight = op(oldWeight, delta);
        
        if (pos > 0 && ckpts[pos - 1].fromBlock == block.number) {
            ckpts[pos - 1].votes = SafeCast.toUint224(newWeight);
        } else {
            ckpts.push(Checkpoint({
                fromBlock: SafeCast.toUint32(block.number),
                votes: SafeCast.toUint224(newWeight)
            }));
        }
    }
}
```

## Delegation Mechanisms

### Direct Delegation
```solidity
function delegate(address delegatee) public override {
    _delegate(_msgSender(), delegatee);
}

function _delegate(address delegator, address delegatee) internal {
    address currentDelegate = delegates(delegator);
    uint256 delegatorBalance = balanceOf(delegator);
    _delegates[delegator] = delegatee;
    
    emit DelegateChanged(delegator, currentDelegate, delegatee);
    
    _moveVotingPower(currentDelegate, delegatee, delegatorBalance);
}

function _moveVotingPower(address src, address dst, uint256 amount) internal {
    if (src != dst && amount > 0) {
        if (src != address(0)) {
            (uint256 oldWeight, uint256 newWeight) = _writeCheckpoint(
                _checkpoints[src], 
                _subtract, 
                amount
            );
            emit DelegateVotesChanged(src, oldWeight, newWeight);
        }
        
        if (dst != address(0)) {
            (uint256 oldWeight, uint256 newWeight) = _writeCheckpoint(
                _checkpoints[dst], 
                _add, 
                amount
            );
            emit DelegateVotesChanged(dst, oldWeight, newWeight);
        }
    }
}
```

### Signature-Based Delegation
```solidity
bytes32 private constant _DELEGATION_TYPEHASH = 
    keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

function delegateBySig(
    address delegatee,
    uint256 nonce,
    uint256 expiry,
    uint8 v,
    bytes32 r,
    bytes32 s
) public override {
    require(block.timestamp <= expiry, "ERC20Votes: signature expired");
    
    address signer = ECDSA.recover(
        _hashTypedDataV4(keccak256(abi.encode(_DELEGATION_TYPEHASH, delegatee, nonce, expiry))),
        v, r, s
    );
    
    require(nonce == _useNonce(signer), "ERC20Votes: invalid nonce");
    _delegate(signer, delegatee);
}
```

## Vote Power Calculations

### Current Vote Power
```solidity
function getVotes(address account) public view override returns (uint256) {
    uint256 pos = _checkpoints[account].length;
    return pos == 0 ? 0 : _checkpoints[account][pos - 1].votes;
}
```

### Historical Vote Power
```solidity
function getPastVotes(address account, uint256 blockNumber) public view override returns (uint256) {
    require(blockNumber < block.number, "ERC20Votes: block not yet mined");
    return _checkpointsLookup(_checkpoints[account], blockNumber);
}

function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) 
    private view returns (uint256) {
    
    uint256 high = ckpts.length;
    uint256 low = 0;
    
    while (low < high) {
        uint256 mid = Math.average(low, high);
        if (ckpts[mid].fromBlock > blockNumber) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }
    
    return high == 0 ? 0 : ckpts[high - 1].votes;
}
```

## Integration with Olla Protocol

### Dual Token Model
```solidity
contract OllaEcosystem {
    IStAztecToken public stAztec;        // Utility token (liquid staking)
    IOllaGovernance public ollaToken;  // Governance token
    
    // Cross-token benefits
    mapping(address => bool) public stAztecHolders;
    mapping(address => uint256) public governanceBonus;
    
    function updateStAztecStatus(address user) external {
        bool hasStAztec = stAztec.balanceOf(user) > 0;
        stAztecHolders[user] = hasStAztec;
        
        if (hasStAztec) {
            // stAztec holders get governance voting bonus
            governanceBonus[user] = calculateGovernanceBonus(user);
        }
    }
}
```

### Governance Rewards
```solidity
contract GovernanceRewards {
    mapping(address => uint256) public lastVoteBlock;
    mapping(address => uint256) public participationScore;
    
    function recordVote(address voter, uint256 proposalId) external onlyGovernor {
        lastVoteBlock[voter] = block.number;
        participationScore[voter]++;
        
        // Reward active governance participation
        _mintGovernanceRewards(voter);
    }
    
    function calculateVotingRewards(address voter) public view returns (uint256) {
        uint256 votes = ollaToken.getVotes(voter);
        uint256 participation = participationScore[voter];
        uint256 recentActivity = _calculateRecentActivity(voter);
        
        return (votes * participation * recentActivity) / 1e18;
    }
}
```

## Delegation Strategies

### Liquid Delegation
```solidity
contract LiquidDelegation {
    mapping(address => mapping(address => uint256)) public partialDelegations;
    
    function delegatePartial(address delegatee, uint256 amount) external {
        require(ollaToken.balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        partialDelegations[msg.sender][delegatee] = amount;
        _updateDelegation(msg.sender);
    }
    
    function _updateDelegation(address delegator) internal {
        // Complex logic for partial delegation management
        // Users can delegate different amounts to different delegates
    }
}
```

### Expert Delegation Networks
```solidity
contract ExpertDelegation {
    struct Expert {
        address expertAddress;
        string expertise;        // "DeFi", "Security", "Tokenomics", etc.
        uint256 reputation;
        uint256 totalDelegated;
    }
    
    mapping(address => Expert) public experts;
    mapping(bytes32 => address[]) public expertsByCategory;
    
    function registerExpert(string memory expertise) external {
        bytes32 category = keccak256(bytes(expertise));
        expertsByCategory[category].push(msg.sender);
        
        experts[msg.sender] = Expert({
            expertAddress: msg.sender,
            expertise: expertise,
            reputation: 0,
            totalDelegated: 0
        });
    }
    
    function delegateToExpert(string memory category, uint256 amount) external {
        bytes32 categoryHash = keccak256(bytes(category));
        address[] memory categoryExperts = expertsByCategory[categoryHash];
        
        // Delegate to highest reputation expert in category
        address bestExpert = _findBestExpert(categoryExperts);
        ollaToken.delegate(bestExpert);
    }
}
```

## Security Considerations

### Double Voting Prevention
```solidity
contract SecureGovernor {
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    
    function castVote(uint256 proposalId, uint8 support) external {
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        
        uint256 votes = ollaToken.getPastVotes(msg.sender, proposal.voteStart);
        require(votes > 0, "No voting power");
        
        hasVoted[proposalId][msg.sender] = true;
        _recordVote(proposalId, msg.sender, support, votes);
    }
}
```

### Delegation Attack Prevention
```solidity
contract DelegationGuard {
    mapping(address => uint256) public lastDelegationChange;
    uint256 public constant DELEGATION_COOLDOWN = 1 days;
    
    modifier delegationCooldown() {
        require(
            block.timestamp >= lastDelegationChange[msg.sender] + DELEGATION_COOLDOWN,
            "Delegation cooldown active"
        );
        _;
        lastDelegationChange[msg.sender] = block.timestamp;
    }
    
    function delegate(address delegatee) external delegationCooldown {
        ollaToken.delegate(delegatee);
    }
}
```

### Flash Loan Protection
```solidity
contract FlashLoanProtection {
    mapping(address => uint256) public minimumHoldingPeriod;
    uint256 public constant MIN_HOLDING_BLOCKS = 17280; // ~3 days
    
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        
        if (to != address(0)) {
            minimumHoldingPeriod[to] = block.number + MIN_HOLDING_BLOCKS;
        }
    }
    
    function getVotes(address account) public view override returns (uint256) {
        if (block.number < minimumHoldingPeriod[account]) {
            return 0; // No voting power during holding period
        }
        return super.getVotes(account);
    }
}
```

## Frontend Integration

### Delegation Interface
```typescript
interface DelegationManager {
  // Query delegation status
  getDelegates(address: string): Promise<string>;
  getVotingPower(address: string): Promise<string>;
  getDelegatedPower(address: string): Promise<string>;
  
  // Delegation actions
  delegate(delegatee: string): Promise<TransactionResult>;
  delegateBySig(
    delegatee: string,
    signature: Signature
  ): Promise<TransactionResult>;
  
  // Delegation analytics
  getDelegationHistory(address: string): Promise<DelegationEvent[]>;
  getTopDelegates(): Promise<Delegate[]>;
}
```

### Vote Tracking Dashboard
```typescript
interface VoteTracker {
  // User voting history
  getVotingHistory(address: string): Promise<Vote[]>;
  getParticipationRate(address: string): Promise<number>;
  
  // Proposal analytics
  getProposalVotes(proposalId: string): Promise<ProposalVotes>;
  getVotingPowerDistribution(proposalId: string): Promise<PowerDistribution>;
  
  // Delegation insights
  getDelegationEffectiveness(delegate: string): Promise<DelegateMetrics>;
  getVotingAlignment(delegator: string, delegate: string): Promise<number>;
}
```

## Testing Strategy

### Delegation Testing
```solidity
contract ERC20VotesTest {
    function testDelegation() public {
        // Mint tokens to user
        ollaToken.mint(user, 1000e18);
        
        // Initial self-delegation
        vm.prank(user);
        ollaToken.delegate(user);
        assertEq(ollaToken.getVotes(user), 1000e18);
        
        // Delegate to expert
        vm.prank(user);
        ollaToken.delegate(expert);
        assertEq(ollaToken.getVotes(user), 0);
        assertEq(ollaToken.getVotes(expert), 1000e18);
    }
    
    function testCheckpoints() public {
        ollaToken.mint(user, 1000e18);
        vm.prank(user);
        ollaToken.delegate(user);
        
        uint256 blockNumber = block.number;
        vm.roll(block.number + 100);
        
        // Historical voting power should be preserved
        assertEq(ollaToken.getPastVotes(user, blockNumber), 1000e18);
    }
}
```

## Delivery alignment (post-V1)

Design governance token distribution and implement ERC20Votes when governance is introduced. Launch delegation system and integrate with OpenZeppelin Governor at governance go-live. Post-launch: advanced delegation strategies, incentives, cross-protocol governance integration.

---

**Tags:** #erc20votes #governance #delegation #voting #checkpoints #dao

**Related Standards:**
- [[ERC-20]] - Base token functionality
- [[ERC-2612]] - Signature-based interactions
- [[OpenZeppelin-Governor]] - Governance framework integration

**Implementation Links:**
- [[../governance/dao-governance]] - DAO governance system
- [[../development/phase-development-analysis]] - Phase 3 implementation
- [[../technical/technical-architecture]] - Governance architecture

**Last Updated:** 2025-10-15
