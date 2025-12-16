# ERC-20: Token Standard

## Overview

The foundational token standard used for stAztec, providing the basic interface for transferable tokens while implementing yield-bearing semantics for liquid staking. stAztec is an ERC-20 token that represents shares in an ERC-7540 vault containing the underlying Aztec tokens.

## Status

**Implementation**: Required for V1 [[../core/stAztec-token-design|stAztec token]]  
**Base**: OpenZeppelin ERC20 implementation  
**Priority**: Critical - Core functionality

## Interface Definition

```solidity
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
```

## Olla-Specific Implementation

### Non-Rebasing Model

- **Balance Semantics**: `balanceOf()` returns shares, not underlying Aztec value
- **Value Accrual**: Token value increases through exchange rate appreciation
- **Transfer Behavior**: Transfers move proportional yield rights, not fixed values
- **Supply Management**: Total supply changes only through minting/burning, not rewards

### Implementation Details

```solidity
contract StAztecToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    IRateAdapter public rateAdapter;
    
    constructor() ERC20("Liquid Staked Aztec", "stAZTEC") {}
    
    // Standard ERC-20 functions work with shares
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account); // Returns shares
    }
    
    // Convenience function for underlying value
    function balanceOfUnderlying(address account) external view returns (uint256) {
        return rateAdapter.convertToAssets(balanceOf(account));
    }
    
    // Controlled minting for deposits
    function mint(address to, uint256 shares) external onlyRole(MINTER_ROLE) {
        _mint(to, shares);
    }
    
    // Controlled burning for withdrawals  
    function burn(address from, uint256 shares) external onlyRole(BURNER_ROLE) {
        _burn(from, shares);
    }
}
```

## DeFi Compatibility

### Standard Interface Benefits

- **Universal Support**: All DeFi protocols can interact with stAztec
- **DEX Integration**: Standard AMM and orderbook compatibility
- **Wallet Support**: All ERC-20 compatible wallets work seamlessly
- **Analytics**: Standard token tracking and portfolio management

### Yield-Bearing Considerations

- **Price Appreciation**: Token value grows over time vs. constant balance
- **Integration Patterns**: External protocols must use rate oracles for accurate pricing
- **Accounting**: Some protocols may need updates to handle non-rebasing yield tokens
- **User Education**: Users need to understand share vs. underlying value semantics

## Gas Optimization

### Efficient Implementation

- **Storage Layout**: Optimized state variable packing
- **Function Selectors**: Short selectors for frequently called functions
- **Batch Operations**: Support for multiple transfers in single transaction
- **Proxy Compatibility**: Upgradeable contract patterns with minimal overhead

### Common Operations Gas Costs

- **Transfer**: ~21,000 gas (standard ERC-20)
- **Approve**: ~45,000 gas (standard ERC-20)
- **Mint/Burn**: ~50,000 gas (includes access control)
- **Balance Queries**: View functions (no gas cost)

## Security Considerations

### Standard Protections

- **Integer Overflow**: SafeMath or Solidity 0.8+ built-in protection
- **Reentrancy**: ReentrancyGuard on state-changing functions
- **Access Control**: Role-based permissions for minting/burning
- **Pausability**: Emergency pause capability for security incidents

### Olla-Specific Risks

- **Rate Oracle Dependency**: Accurate underlying value depends on oracle health
- **Minting/Burning Control**: Critical that only authorized contracts can mint/burn
- **Share Calculation**: Precision loss in share/asset conversions
- **Upgrade Safety**: Token upgrades must preserve user balances

## Integration Examples

### DEX Pool Creation

```solidity
// Uniswap V3 pool creation example
IUniswapV3Factory factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

address pool = factory.createPool(
    address(stAztecToken),  // token0
    address(aztecToken),   // token1  
    3000                   // 0.3% fee tier
);

// Initialize with current exchange rate
IUniswapV3Pool(pool).initialize(
    getSqrtPriceX96FromRate(rateAdapter.getExchangeRate())
);
```

### Lending Protocol Integration

```solidity
// Compound-style lending integration
interface ICToken {
    function mint(uint mintAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
    function getUnderlyingPrice() external view returns (uint);
}

contract stAztecCToken is ICToken {
    function getUnderlyingPrice() external view override returns (uint) {
        // Use rate adapter for accurate pricing
        return rateAdapter.getExchangeRate();
    }
}
```

## Delivery alignment (V1 and beyond)

- **V1**: Deploy stAztec ERC20 with mint/burn gated to OllaCore; include EIP-2612 permit; integrate with ERC-7540 vault semantics; provide rate adapter for share-to-asset conversions.
- **Post-V1**: Optional ERC-1271 support, governance hooks, bridge and cross-chain mobility, further gas tuning.

---

**Tags:** #erc-20 #token-standard #stAztec #yield-bearing #defi-compatibility

**Related Standards:**

- [[ERC-2612]] - Gasless approvals for improved UX
- [[ERC-1271]] - Smart contract wallet support
- [[ERC-7540]] - Async vault operations

**Implementation Links:**

- [[../core/stAztec-token-design]] - Complete token design
- [[../technical/technical-architecture]] - System architecture
- [[../integrations/defi-integrations]] - DeFi integration patterns

**Last Updated:** 2025-10-15
