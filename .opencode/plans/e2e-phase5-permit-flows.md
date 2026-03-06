# Phase 5: Permit-Based Deposit and Redeem Flows

**Risk**: Medium — `depositWithPermit()` and `requestRedeemWithPermit()` use ERC-2612 permit signatures to set allowances gaslessly. The try/catch wrapping of permit errors, signature edge cases, and slippage interaction need e2e validation.

## Scope

Validate that:
- Valid ERC-2612 permits enable deposit and redeem request without prior `approve()`
- Expired deadlines, wrong signers, and replay attempts revert with `OllaVault__PermitFailed`
- Slippage protection (`minSharesOut`) works correctly in permit flows
- Nonce increment prevents signature replay
- Frontrunning edge case is documented

## Prerequisites

- OllaCore, OllaVault, WithdrawalQueue, StAztec (real, proxied)
- MockAztec must implement ERC-2612 (`permit()` on the asset token)
- StAztec must implement ERC-2612 (`permit()` on the share token)
- Forge `vm.sign(privateKey, digest)` for EIP-712 signing

## Implementation Steps

### 1. Verify MockAztec and StAztec support ERC-2612

Check that both tokens expose:
- `permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)`
- `nonces(address owner) returns (uint256)`
- `DOMAIN_SEPARATOR() returns (bytes32)`

If MockAztec does not support ERC-2612, the test will need to deploy an ERC20Permit mock instead.

### 2. Create test contract with signing helpers

```solidity
// contracts/test/e2e/PermitFlows.e2e.t.sol

contract PermitFlowsE2ETest is Test {
    // Full stack (simplified — permit is the focus, not staking)
    // Can use MockAccountingStakingManager for staking operations

    uint256 internal aliceKey;
    address internal alice;
    uint256 internal bobKey;
    address internal bob;

    function setUp() external {
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        // Deploy full stack, unpause
    }
}
```

### 3. EIP-712 permit digest builder

```solidity
function _buildPermitDigest(
    address token,
    address owner,
    address spender,
    uint256 value,
    uint256 nonce,
    uint256 deadline
) internal view returns (bytes32) {
    bytes32 PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
    bytes32 domainSeparator = IERC20Permit(token).DOMAIN_SEPARATOR();
    return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
}

function _signPermit(
    address token,
    uint256 ownerKey,
    address owner,
    address spender,
    uint256 value,
    uint256 deadline
) internal view returns (uint8 v, bytes32 r, bytes32 s) {
    uint256 nonce = IERC20Permit(token).nonces(owner);
    bytes32 digest = _buildPermitDigest(token, owner, spender, value, nonce, deadline);
    (v, r, s) = vm.sign(ownerKey, digest);
}
```

## Test Cases

### Test 5a: `test_DepositWithPermit_HappyPath`

```
Setup:
  1. asset.mint(alice, 100e18)

Actions:
  2. Build permit: owner=alice, spender=vault, value=100e18, deadline=block.timestamp+1h
  3. Sign with aliceKey
  4. vm.prank(alice);
     vault.depositWithPermit(100e18, alice, 0, deadline, v, r, s);

Assertions:
  - stAztec.balanceOf(alice) == 100e18
  - asset.balanceOf(address(vault)) == 100e18
  - asset.allowance(alice, address(vault)) == 0 (permit consumed exactly)
  - asset.nonces(alice) == 1
```

### Test 5b: `test_DepositWithPermit_ExpiredDeadline_Reverts`

```
Setup:
  1. asset.mint(alice, 100e18)

Actions:
  2. deadline = block.timestamp - 1 (already expired)
  3. Sign permit with aliceKey
  4. vm.prank(alice);
     vm.expectRevert(); // OllaVault__PermitFailed wrapping ERC2612ExpiredSignature
     vault.depositWithPermit(100e18, alice, 0, deadline, v, r, s);

Assertions:
  - Transaction reverts
  - No tokens transferred, no shares minted
  - asset.nonces(alice) == 0 (nonce not consumed)
```

### Test 5c: `test_DepositWithPermit_WrongSigner_Reverts`

```
Setup:
  1. asset.mint(alice, 100e18)

Actions:
  2. Build permit for alice's deposit but sign with bobKey
  3. vm.prank(alice);
     vm.expectRevert(); // OllaVault__PermitFailed wrapping ERC2612InvalidSigner
     vault.depositWithPermit(100e18, alice, 0, deadline, v, r, s);

Assertions:
  - Transaction reverts
  - No state changes
```

### Test 5d: `test_DepositWithPermit_SlippageProtection`

```
Setup:
  1. alice deposits 100e18 normally (rate = 1:1)
  2. Simulate 10e18 rewards, full rebalance → rate > 1
  3. Record newRate = core.exchangeRate()

Actions:
  4. asset.mint(bob, 100e18)
  5. Sign permit for bob → vault, value=100e18
  6. expectedShares = 100e18 * 1e18 / newRate (will be < 100e18)
  7. vm.prank(bob);
     vm.expectRevert(); // OllaVault__SlippageExceeded
     vault.depositWithPermit(100e18, bob, 100e18, deadline, v, r, s);
     // minSharesOut = 100e18 but actual shares < 100

  8. vm.prank(bob);
     vault.depositWithPermit(100e18, bob, expectedShares, deadline2, v2, r2, s2);
     // New permit needed (nonce consumed on revert? No — permit reverted, nonce unchanged)
     // Actually: the entire tx reverts, so nonce is NOT consumed. Same signature works.

Assertions:
  - Step 7 reverts with slippage error
  - Step 8: bob gets expectedShares (< 100e18)
  - Note: need fresh permit signature if nonce changed, but since step 7 reverted, nonce is still 0
```

### Test 5e: `test_RequestRedeemWithPermit_HappyPath`

```
Setup:
  1. alice deposits 100e18 → 100e18 stAztec

Actions:
  2. Build permit on stAztec: owner=alice, spender=vault, value=50e18
  3. Sign with aliceKey
  4. vm.prank(alice);
     requestId = vault.requestRedeemWithPermit(50e18, alice, deadline, v, r, s);

Assertions:
  - requestId > 0
  - stAztec.balanceOf(alice) == 50e18 (50 burned)
  - WithdrawalRequest: shares=50e18, assetsExpected=50e18, rate=1e18
  - stAztec.nonces(alice) == 1
  - stAztec.allowance(alice, vault) == 0
```

### Test 5f: `test_RequestRedeemWithPermit_ReplayPrevented`

```
Setup:
  1. alice deposits 100e18 → 100e18 stAztec

Actions:
  2. Sign permit for 30e18 stAztec
  3. First call: vault.requestRedeemWithPermit(30e18, alice, deadline, v, r, s) → succeeds
  4. Second call: same (v, r, s) → reverts

Assertions:
  - First call: requestId = 1, alice has 70e18 shares
  - Second call: reverts with OllaVault__PermitFailed (nonce now 1, signature was for nonce 0)
  - stAztec.nonces(alice) == 1 (incremented once)
```

### Test 5g: `test_DepositWithPermit_FrontrunApprove_DocumentedBehavior`

```
Purpose: Document what happens when a frontrunner uses the permit signature before
the user's depositWithPermit tx lands. The current implementation wraps permit()
in try/catch and reverts with OllaVault__PermitFailed if permit fails.

Setup:
  1. asset.mint(alice, 100e18)

Actions:
  2. alice signs permit for vault, 100e18
  3. Attacker calls asset.permit(alice, vault, 100e18, deadline, v, r, s) directly
     → allowance is now set, nonce incremented
  4. alice calls vault.depositWithPermit(100e18, alice, 0, deadline, v, r, s)
     → vault's try permit() reverts (nonce already consumed)
     → catch wraps as OllaVault__PermitFailed → tx reverts

Assertions:
  - Step 3 succeeds (attacker set the allowance)
  - Step 4 reverts with OllaVault__PermitFailed
  - alice still has allowance set (from attacker's frontrun)
  - alice can fall back to normal vault.deposit(100e18, alice, 0) which uses the allowance
  - Deposit succeeds via the fallback path

Notes:
  This documents a known UX limitation: the try/catch does not check whether
  the allowance is already sufficient before reverting. Users whose permit
  signatures get frontrun must use the non-permit deposit() as a fallback.
```

## Acceptance Criteria

- [ ] Valid permit signatures enable deposit and redeem request without prior approve
- [ ] Expired deadline reverts with `OllaVault__PermitFailed`
- [ ] Wrong signer reverts with `OllaVault__PermitFailed`
- [ ] Nonce increments correctly — replay of same signature reverts
- [ ] `minSharesOut` slippage check works in permit deposit flow
- [ ] `requestRedeemWithPermit` uses stAztec's permit (not asset's)
- [ ] Permit failures leave no side effects (no shares minted, no tokens transferred)
- [ ] Frontrunning behavior documented: permit try/catch does not gracefully handle pre-set allowance

## Verification

```bash
forge test --match-contract PermitFlowsE2ETest -vvv
```
