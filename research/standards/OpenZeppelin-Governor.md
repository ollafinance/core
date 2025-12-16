# OpenZeppelin Governor Framework

## Overview
OpenZeppelin Governor is a comprehensive governance framework that provides modular, secure, and flexible on-chain governance capabilities. It works seamlessly with ERC20Votes tokens to enable decentralized protocol management.

## Status
**Implementation**: Post-V1 (governance scope)  
**Priority**: Critical once governance goes live  
**Base**: Modular governance system with multiple extensions

## Core Architecture

### Governor Base Contract
```solidity
abstract contract Governor is Context, ERC165, EIP712 {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }
    
    struct ProposalCore {
        Timers.BlockNumber voteStart;
        Timers.BlockNumber voteEnd;
        bool executed;
        bool canceled;
    }
    
    mapping(uint256 => ProposalCore) private _proposals;
    
    // Core governance functions
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual returns (uint256);
    
    function castVote(uint256 proposalId, uint8 support) public virtual returns (uint256);
    
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual returns (uint256);
}
```

### Olla Governor Implementation
```solidity
contract OllaGovernor is 
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    AccessControl
{
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    
    constructor(
        IVotes _token,
        TimelockController _timelock,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumPercentage
    )
        Governor("OllaGovernor")
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumPercentage)
        GovernorTimelockControl(_timelock)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROPOSER_ROLE, address(_timelock));
        _grantRole(EXECUTOR_ROLE, address(_timelock));
        _grantRole(TIMELOCK_ADMIN_ROLE, address(_timelock));
    }
    
    // Override required functions for multiple inheritance
    function votingDelay() public view override(IGovernor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }
    
    function votingPeriod() public view override(IGovernor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }
    
    function quorum(uint256 blockNumber) 
        public view override(IGovernor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(blockNumber);
    }
    
    function proposalThreshold() 
        public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }
}
```

## Governor Extensions

### GovernorSettings
Configurable governance parameters:
```solidity
abstract contract GovernorSettings is Governor {
    uint256 private _votingDelay;
    uint256 private _votingPeriod;
    uint256 private _proposalThreshold;
    
    function setVotingDelay(uint256 newVotingDelay) public virtual onlyGovernance {
        _setVotingDelay(newVotingDelay);
    }
    
    function setVotingPeriod(uint256 newVotingPeriod) public virtual onlyGovernance {
        _setVotingPeriod(newVotingPeriod);
    }
    
    function setProposalThreshold(uint256 newProposalThreshold) public virtual onlyGovernance {
        _setProposalThreshold(newProposalThreshold);
    }
}
```

### GovernorCountingSimple
Simple voting mechanism (For, Against, Abstain):
```solidity
abstract contract GovernorCountingSimple is Governor {
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
    }
    
    mapping(uint256 => ProposalVote) private _proposalVotes;
    
    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 weight,
        bytes memory // params
    ) internal virtual override {
        ProposalVote storage proposalvote = _proposalVotes[proposalId];
        
        require(!proposalvote.hasVoted[account], "GovernorVotingSimple: vote already cast");
        proposalvote.hasVoted[account] = true;
        
        if (support == uint8(VoteType.Against)) {
            proposalvote.againstVotes += weight;
        } else if (support == uint8(VoteType.For)) {
            proposalvote.forVotes += weight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposalvote.abstainVotes += weight;
        } else {
            revert("GovernorVotingSimple: invalid value for enum VoteType");
        }
    }
}
```

### GovernorVotesQuorumFraction
Dynamic quorum based on token supply:
```solidity
abstract contract GovernorVotesQuorumFraction is GovernorVotes {
    uint256 private _quorumNumerator;
    
    function quorum(uint256 blockNumber) public view virtual override returns (uint256) {
        return (_quorumNumerator * token.getPastTotalSupply(blockNumber)) / _quorumDenominator();
    }
    
    function updateQuorumNumerator(uint256 newQuorumNumerator) external virtual onlyGovernance {
        _updateQuorumNumerator(newQuorumNumerator);
    }
}
```

## Timelock Integration

### TimelockController
```solidity
contract OllaTimelock is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
    
    // Custom timelock functions for Olla protocol
    function scheduleParameterUpdate(
        address target,
        bytes32 parameter,
        uint256 newValue,
        uint256 delay
    ) external onlyRole(PROPOSER_ROLE) {
        bytes memory data = abi.encodeWithSignature(
            "updateParameter(bytes32,uint256)",
            parameter,
            newValue
        );
        
        schedule(target, 0, data, bytes32(0), bytes32(0), delay);
    }
}
```

### GovernorTimelockControl Integration
```solidity
abstract contract GovernorTimelockControl is Governor {
    TimelockController private _timelock;
    mapping(uint256 => bytes32) private _timelockIds;
    
    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override {
        bytes32 timelockId = _timelockIds[proposalId];
        delete _timelockIds[proposalId];
        
        _timelock.executeBatch(targets, values, calldatas, 0, descriptionHash);
    }
    
    function _queue(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual override returns (uint48) {
        uint256 delay = _timelock.getMinDelay();
        bytes32 timelockId = _timelock.hashOperationBatch(
            targets, values, calldatas, 0, descriptionHash
        );
        
        _timelockIds[proposalId] = timelockId;
        _timelock.scheduleBatch(targets, values, calldatas, 0, descriptionHash, delay);
        
        return SafeCast.toUint48(block.timestamp + delay);
    }
}
```

## Olla-Specific Governance Patterns

### Parameter Management
```solidity
contract ParameterGovernance {
    struct ParameterProposal {
        bytes32 parameterKey;
        uint256 currentValue;
        uint256 proposedValue;
        string rationale;
        uint256 impact; // Estimated impact score
    }
    
    mapping(uint256 => ParameterProposal) public parameterProposals;
    
    function proposeParameterChange(
        bytes32 parameterKey,
        uint256 newValue,
        string memory rationale
    ) external returns (uint256 proposalId) {
        
        uint256 currentValue = parameterRegistry.getParameter(parameterKey);
        uint256 impact = _calculateImpact(parameterKey, currentValue, newValue);
        
        // Create governance proposal
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        
        targets[0] = address(parameterRegistry);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature(
            "updateParameter(bytes32,uint256)",
            parameterKey,
            newValue
        );
        
        proposalId = propose(
            targets,
            values, 
            calldatas,
            string(abi.encodePacked("Parameter Update: ", rationale))
        );
        
        parameterProposals[proposalId] = ParameterProposal({
            parameterKey: parameterKey,
            currentValue: currentValue,
            proposedValue: newValue,
            rationale: rationale,
            impact: impact
        });
    }
}
```

### Operator Management
```solidity
contract OperatorGovernance {
    function proposeOperatorAddition(
        address operatorAddress,
        string memory metadataURI,
        uint256 stakingCap
    ) external returns (uint256 proposalId) {
        
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        
        targets[0] = address(operatorRegistry);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature(
            "approveOperator(address,string,uint256)",
            operatorAddress,
            metadataURI,
            stakingCap
        );
        
        return propose(
            targets,
            values,
            calldatas,
            string(abi.encodePacked("Add Operator: ", metadataURI))
        );
    }
    
    function proposeOperatorRemoval(
        address operatorAddress,
        string memory reason
    ) external returns (uint256 proposalId) {
        
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        
        targets[0] = address(operatorRegistry);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature(
            "removeOperator(address)",
            operatorAddress
        );
        
        return propose(
            targets,
            values,
            calldatas,
            string(abi.encodePacked("Remove Operator: ", reason))
        );
    }
}
```

### Emergency Governance
```solidity
contract EmergencyGovernance {
    enum EmergencyType {
        PARAMETER_URGENT,
        SECURITY_INCIDENT,
        ORACLE_FAILURE,
        OPERATOR_MISBEHAVIOR
    }
    
    struct EmergencyProposal {
        EmergencyType emergencyType;
        uint256 expeditedVotingPeriod; // Shorter than normal
        uint256 minimumQuorum;         // Higher than normal
        bool requiresSupermajority;    // 66% vs 50%
    }
    
    mapping(uint256 => EmergencyProposal) public emergencyProposals;
    
    function proposeEmergencyAction(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        EmergencyType emergencyType
    ) external onlyRole(GUARDIAN_ROLE) returns (uint256 proposalId) {
        
        proposalId = propose(targets, values, calldatas, description);
        
        emergencyProposals[proposalId] = EmergencyProposal({
            emergencyType: emergencyType,
            expeditedVotingPeriod: 24 hours,     // vs 7 days normal
            minimumQuorum: 15,                   // vs 4% normal  
            requiresSupermajority: true          // vs false normal
        });
        
        emit EmergencyProposalCreated(proposalId, emergencyType);
    }
    
    function votingPeriod() public view override returns (uint256) {
        // Check if current proposal is emergency
        uint256 currentProposal = getCurrentProposal();
        if (emergencyProposals[currentProposal].emergencyType != EmergencyType(0)) {
            return emergencyProposals[currentProposal].expeditedVotingPeriod;
        }
        return super.votingPeriod();
    }
}
```

## Governance Security Features

### Proposal Validation
```solidity
contract SecureGovernor is OllaGovernor {
    mapping(address => bool) public trustedTargets;
    mapping(bytes4 => bool) public allowedSelectors;
    
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        
        // Validate proposal targets and functions
        for (uint i = 0; i < targets.length; i++) {
            require(trustedTargets[targets[i]], "Untrusted target");
            
            bytes4 selector = bytes4(calldatas[i][:4]);
            require(allowedSelectors[selector], "Unauthorized function");
        }
        
        return super.propose(targets, values, calldatas, description);
    }
}
```

### Vote Validation
```solidity
contract AntiManipulationGovernor is OllaGovernor {
    mapping(address => uint256) public lastTransfer;
    uint256 public constant TRANSFER_VOTING_DELAY = 1 days;
    
    function _getVotes(
        address account, 
        uint256 blockNumber, 
        bytes memory /*params*/
    ) internal view override returns (uint256) {
        
        // Prevent flash loan governance attacks
        require(
            lastTransfer[account] + TRANSFER_VOTING_DELAY <= blockNumber,
            "Recent token transfer"
        );
        
        return super._getVotes(account, blockNumber, "");
    }
}
```

## Frontend Integration

### Proposal Creation Interface
```typescript
interface ProposalCreator {
  // Parameter proposals
  createParameterProposal(
    parameter: string,
    newValue: string,
    rationale: string
  ): Promise<ProposalCreationResult>;
  
  // Operator proposals  
  createOperatorProposal(
    action: 'add' | 'remove',
    operatorAddress: string,
    details: OperatorDetails
  ): Promise<ProposalCreationResult>;
  
  // Custom proposals
  createCustomProposal(
    targets: string[],
    values: string[],
    calldatas: string[],
    description: string
  ): Promise<ProposalCreationResult>;
}
```

### Voting Interface
```typescript
interface VotingInterface {
  // Cast votes
  castVote(proposalId: string, support: VoteType): Promise<VoteResult>;
  castVoteWithReason(
    proposalId: string,
    support: VoteType,
    reason: string
  ): Promise<VoteResult>;
  
  // Vote delegation
  delegateVotes(delegatee: string): Promise<DelegationResult>;
  
  // Voting analytics
  getVotingPower(address: string, blockNumber?: number): Promise<string>;
  getProposalVotes(proposalId: string): Promise<ProposalVotes>;
  getUserVotingHistory(address: string): Promise<VoteHistory[]>;
}
```

## Testing Strategy

### Governance Flow Testing
```solidity
contract GovernorTest {
    function testParameterProposal() public {
        // Create proposal
        uint256 proposalId = governor.proposeParameterChange(
            "STAKING_FEE",
            500, // 5%
            "Reduce staking fee to improve competitiveness"
        );
        
        // Advance to voting period
        vm.roll(block.number + governor.votingDelay());
        
        // Cast votes
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For
        
        vm.prank(voter2); 
        governor.castVote(proposalId, 0); // Against
        
        // Advance to end of voting
        vm.roll(block.number + governor.votingPeriod());
        
        // Queue proposal
        governor.queue(proposalId);
        
        // Advance timelock delay
        vm.warp(block.timestamp + timelock.getMinDelay());
        
        // Execute proposal
        governor.execute(proposalId);
        
        // Verify parameter was updated
        assertEq(parameterRegistry.getParameter("STAKING_FEE"), 500);
    }
}
```

## Delivery alignment (post-V1)
- Prepare TimelockController, roles, and governance token distribution for governance go-live.
- Deploy OllaGovernor and transfer control only after audits and conservative parameter setup.
- Evolve with parameter tuning, advanced voting mechanisms, and cross-protocol integration after launch.

---

**Tags:** #openzeppelin-governor #governance #dao #timelock #voting #proposals

**Related Standards:**
- [[ERC20Votes]] - Voting token integration
- [[ERC-2612]] - Signature-based voting
- [[ERC-1271]] - Smart contract voting

**Implementation Links:**
- [[../governance/dao-governance]] - Complete governance system
- [[../development/phase-development-analysis]] - Phase 3 implementation
- [[../operations/risk-assessment]] - Governance security considerations

**Last Updated:** 2025-10-15
