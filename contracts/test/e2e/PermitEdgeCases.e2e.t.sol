// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

/// @title PermitEdgeCasesE2E
/// @notice Phase 6 E2E: exercises permit frontrun protection catch blocks,
///         operator-based ERC-7540 redemption flows, nonce management, and edge cases.
contract PermitEdgeCasesE2E is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;
    uint256 internal constant BP_DIVISOR = 10_000;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaGovernance internal gov;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    SafetyModule internal safetyModule;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockAztec internal asset;

    address internal admin;
    address internal guardian;
    address internal operator;
    address internal treasury;
    address internal providerRewards;

    uint256 internal aliceKey;
    address internal alice;
    uint256 internal bobKey;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        operator = makeAddr("operator");
        treasury = makeAddr("treasury");
        providerRewards = makeAddr("providerRewards");

        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");

        asset = new MockAztec(address(this));

        // ---- Deploy OllaGovernance (impl + proxy + init) ----
        OllaGovernance govImpl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(OllaGovernance.initialize, (MIN_DELAY, proposers, executors, admin, treasury))
        );
        gov = OllaGovernance(payable(address(govProxy)));

        // ---- Deploy OllaCore (impl + proxy) ----
        OllaCore coreImpl = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        core = OllaCore(address(coreProxy));

        // ---- Deploy OllaVault (impl + proxy) ----
        OllaVault vaultImpl = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        vault = OllaVault(address(vaultProxy));

        // ---- Deploy satellite contracts ----
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new SafetyModule(
            admin,
            guardian,
            address(core),
            address(vault),
            1_000_000 * DECIMALS, // depositCap
            500, // minRateDropBps (5%)
            6_000, // maxQueueRatioBps (60%)
            7 days // maxAccountingDelay
        );
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(0);

        // ---- Configure mock staking manager ----
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setUnstakedToken(asset);
        stakingManager.setProviderRewardsRecipient(providerRewards);

        // ---- Initialize OllaCore ----
        core.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            address(gov),
            rewardsAccumulator,
            address(safetyModule)
        );

        // ---- Initialize OllaVault ----
        vault.initialize(asset, stAztec, address(core), address(gov));

        // ---- Wire contracts ----
        vm.prank(address(gov));
        core.setVault(address(vault));
        vm.prank(address(gov));
        gov.setCore(address(core));

        // ---- Unpause ----
        vm.prank(address(gov));
        core.unpause();
        vm.prank(address(gov));
        vault.unpause();

        // ---- Advance past rebalance cooldown ----
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address depositor, uint256 amount) internal returns (uint256 shares) {
        asset.mint(depositor, amount);
        vm.prank(depositor);
        asset.approve(address(vault), amount);
        vm.prank(depositor);
        shares = vault.deposit(amount, depositor, 0);
    }

    function _fullRebalance() internal returns (uint256, uint256, uint256, uint256) {
        vm.prank(operator);
        return core.rebalance();
    }

    function _warpPastCooldown() internal {
        vm.warp(block.timestamp + 1 hours + 1);
    }

    function _baselineRebalance() internal {
        vm.prank(address(gov));
        core.setTargetBufferedAssets(1_000_000 * DECIMALS);
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
        _fullRebalance();
    }

    /// @dev Builds an EIP-712 permit digest for a given token.
    function _buildPermitDigest(
        address token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 domainSeparator = IERC20Permit(token).DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @dev Signs an EIP-2612 permit for a given token, looking up the current nonce.
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

    /*//////////////////////////////////////////////////////////////
        6A: DEPOSIT WITH PERMIT — FRONTRUN PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Attacker frontruns the permit signature but the deposit still succeeds
    ///         because the catch block detects sufficient allowance and falls through.
    function test_DepositWithPermit_FrontrunProtection() external {
        asset.mint(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(asset), aliceKey, alice, address(vault), 100 * DECIMALS, deadline);

        // Attacker frontruns the permit
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        IERC20Permit(address(asset)).permit(alice, address(vault), 100 * DECIMALS, deadline, v, r, s);

        assertEq(asset.allowance(alice, address(vault)), 100 * DECIMALS, "allowance set by attacker");
        assertEq(IERC20Permit(address(asset)).nonces(alice), 1, "nonce consumed by attacker");

        // Alice's depositWithPermit succeeds via catch block fallthrough
        vm.prank(alice);
        uint256 shares = vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v, r, s);

        assertEq(shares, 100 * DECIMALS, "alice should receive shares despite frontrun");
        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "alice stAztec balance correct");
        assertEq(asset.balanceOf(address(vault)), 100 * DECIMALS, "vault holds deposited assets");
        assertEq(asset.allowance(alice, address(vault)), 0, "allowance consumed by deposit");
    }

    /*//////////////////////////////////////////////////////////////
        6B: REQUEST REDEEM WITH PERMIT — FRONTRUN PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Attacker frontruns the stAztec permit but requestRedeem still succeeds.
    function test_RequestRedeemWithPermit_FrontrunProtection() external {
        _performDeposit(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(stAztec), aliceKey, alice, address(vault), 50 * DECIMALS, deadline);

        // Attacker frontruns the stAztec permit
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        IERC20Permit(address(stAztec)).permit(alice, address(vault), 50 * DECIMALS, deadline, v, r, s);

        assertEq(stAztec.allowance(alice, address(vault)), 50 * DECIMALS, "stAztec allowance set by attacker");
        assertEq(IERC20Permit(address(stAztec)).nonces(alice), 1, "stAztec nonce consumed by attacker");

        // Alice's requestRedeemWithPermit succeeds via catch block fallthrough
        vm.prank(alice);
        uint256 requestId = vault.requestRedeemWithPermit(50 * DECIMALS, alice, deadline, v, r, s);

        assertGt(requestId, 0, "redeem request created");
        assertEq(stAztec.balanceOf(alice), 50 * DECIMALS, "alice should have 50e18 shares remaining");
        assertEq(stAztec.allowance(alice, address(vault)), 0, "allowance consumed by transferFrom");

        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(req.shares, 50 * DECIMALS, "request for correct share amount");
        assertFalse(req.finalized, "request not yet finalized");
    }

    /*//////////////////////////////////////////////////////////////
        6D: DEPOSIT WITH PERMIT — INVALID SIGNATURE REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invalid signature with no pre-existing allowance correctly reverts.
    function test_DepositWithPermit_InvalidSignature_Reverts() external {
        asset.mint(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;
        // Sign with bob's key but claim alice as owner
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(asset), bobKey, alice, address(vault), 100 * DECIMALS, deadline);

        vm.prank(alice);
        vm.expectRevert(); // OllaVault__PermitFailed (invalid signer, no allowance fallback)
        vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v, r, s);

        assertEq(stAztec.balanceOf(alice), 0, "no shares minted");
        assertEq(asset.balanceOf(alice), 100 * DECIMALS, "alice retains assets");
    }

    /*//////////////////////////////////////////////////////////////
        6E: REQUEST REDEEM WITH PERMIT — EXPIRED DEADLINE
    //////////////////////////////////////////////////////////////*/

    /// @notice Expired deadline with no pre-existing allowance reverts.
    function test_RequestRedeemWithPermit_ExpiredDeadline_Reverts() external {
        _performDeposit(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(stAztec), aliceKey, alice, address(vault), 50 * DECIMALS, deadline);

        vm.prank(alice);
        vm.expectRevert(); // OllaVault__PermitFailed (expired, no allowance)
        vault.requestRedeemWithPermit(50 * DECIMALS, alice, deadline, v, r, s);

        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "alice shares unchanged");
    }

    /// @notice Expired deadline but pre-existing allowance allows fallthrough.
    function test_RequestRedeemWithPermit_ExpiredDeadline_FallsThrough_WithAllowance() external {
        _performDeposit(alice, 100 * DECIMALS);

        // Alice manually approves the vault for stAztec
        vm.prank(alice);
        stAztec.approve(address(vault), 50 * DECIMALS);

        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(stAztec), aliceKey, alice, address(vault), 50 * DECIMALS, deadline);

        // Permit fails (expired) but allowance exists → proceeds
        vm.prank(alice);
        uint256 requestId = vault.requestRedeemWithPermit(50 * DECIMALS, alice, deadline, v, r, s);

        assertGt(requestId, 0, "redeem request created via allowance fallthrough");
        assertEq(stAztec.balanceOf(alice), 50 * DECIMALS, "alice shares burned");
    }

    /*//////////////////////////////////////////////////////////////
        6F: OPERATOR REDEMPTION — SET AND USE
    //////////////////////////////////////////////////////////////*/

    /// @notice Operator can submit requestRedeem on behalf of a user via ERC-7540.
    function test_OperatorRedemption_SetAndUse() external {
        _performDeposit(alice, 100 * DECIMALS);

        // Alice approves bob as operator
        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(vault.isOperator(alice, bob), "bob should be alice's operator");

        // Alice approves stAztec for the vault (required for burn, though vault burns directly)
        // The vault burns via stAztec.burn(owner, shares) which is authorized by OLLA_VAULT role,
        // not by allowance. No stAztec approval needed for the burn.

        // Bob (operator) calls requestRedeem on behalf of alice
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(50 * DECIMALS, alice, alice);

        assertGt(requestId, 0, "redeem request created by operator");
        assertEq(stAztec.balanceOf(alice), 50 * DECIMALS, "alice shares burned by operator request");

        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(req.shares, 50 * DECIMALS, "request for 50e18 shares");
        assertFalse(req.finalized, "request not finalized");
    }

    /*//////////////////////////////////////////////////////////////
        6G: OPERATOR REDEMPTION — UNAUTHORIZED
    //////////////////////////////////////////////////////////////*/

    /// @notice Non-approved operator cannot requestRedeem on behalf of another user.
    function test_OperatorRedemption_Unauthorized() external {
        _performDeposit(alice, 100 * DECIMALS);

        // Bob is NOT approved as operator
        assertFalse(vault.isOperator(alice, bob), "bob should not be alice's operator");

        vm.prank(bob);
        vm.expectRevert(IOllaVault.OllaVault__Unauthorized.selector);
        vault.requestRedeem(50 * DECIMALS, alice, alice);

        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "alice shares unchanged");
    }

    /*//////////////////////////////////////////////////////////////
        6H: PERMIT NONCE INCREMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Two permits signed with same nonce: first succeeds, second enters catch block.
    ///         Without fallback allowance, the second call reverts.
    function test_PermitNonceIncrement_SecondReverts() external {
        asset.mint(alice, 200 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;

        // Sign first permit at nonce 0
        (uint8 v1, bytes32 r1, bytes32 s1) =
            _signPermit(address(asset), aliceKey, alice, address(vault), 100 * DECIMALS, deadline);

        // Sign second permit also at nonce 0 (same nonce, different amount)
        uint256 nonce0 = IERC20Permit(address(asset)).nonces(alice);
        assertEq(nonce0, 0, "nonce should be 0");
        bytes32 digest2 = _buildPermitDigest(address(asset), alice, address(vault), 100 * DECIMALS, 0, deadline);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(aliceKey, digest2);

        // First deposit succeeds (nonce 0 → 1)
        vm.prank(alice);
        uint256 shares1 = vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v1, r1, s1);
        assertEq(shares1, 100 * DECIMALS, "first deposit should succeed");
        assertEq(IERC20Permit(address(asset)).nonces(alice), 1, "nonce should be 1");

        // Second deposit with same-nonce signature reverts (no allowance left — first consumed it)
        vm.prank(alice);
        vm.expectRevert(); // OllaVault__PermitFailed (nonce mismatch, no allowance)
        vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v2, r2, s2);

        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "only first deposit minted shares");
    }

    /// @notice Two permits signed with same nonce: first succeeds, second enters catch block.
    ///         With pre-existing allowance, the second call succeeds via fallthrough.
    function test_PermitNonceIncrement_SecondSucceeds_WithAllowance() external {
        asset.mint(alice, 200 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;

        // Sign first permit at nonce 0
        (uint8 v1, bytes32 r1, bytes32 s1) =
            _signPermit(address(asset), aliceKey, alice, address(vault), 100 * DECIMALS, deadline);

        // First deposit succeeds (nonce 0 → 1)
        vm.prank(alice);
        vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v1, r1, s1);
        assertEq(IERC20Permit(address(asset)).nonces(alice), 1, "nonce should be 1");

        // Alice sets allowance manually for the second deposit
        vm.prank(alice);
        asset.approve(address(vault), 100 * DECIMALS);

        // Sign with stale nonce 0 — permit fails but allowance exists → succeeds
        bytes32 digest = _buildPermitDigest(address(asset), alice, address(vault), 100 * DECIMALS, 0, deadline);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(aliceKey, digest);

        vm.prank(alice);
        uint256 shares2 = vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v2, r2, s2);

        assertEq(shares2, 100 * DECIMALS, "second deposit succeeds via allowance fallthrough");
        assertEq(stAztec.balanceOf(alice), 200 * DECIMALS, "both deposits minted shares");
    }

    /*//////////////////////////////////////////////////////////////
        6I: DEPOSIT WITH PERMIT — ZERO AMOUNT
    //////////////////////////////////////////////////////////////*/

    /// @notice Depositing zero amount reverts with InvalidAmount.
    function test_DepositWithPermit_ZeroAmount_Reverts() external {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(asset), aliceKey, alice, address(vault), 0, deadline);

        vm.prank(alice);
        vm.expectRevert(); // OllaVault__InvalidAmount (from _deposit validation)
        vault.depositWithPermit(0, alice, 0, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
        6J: OPERATOR — SELF-APPROVE REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A user cannot set themselves as their own operator.
    function test_OperatorSelfApprove_Reverts() external {
        vm.prank(alice);
        vm.expectRevert(IOllaVault.OllaVault__InvalidParameter.selector);
        vault.setOperator(alice, true);
    }

    /*//////////////////////////////////////////////////////////////
        6K: OPERATOR — REVOKE AND VERIFY
    //////////////////////////////////////////////////////////////*/

    /// @notice Operator approval can be revoked, blocking subsequent requests.
    function test_OperatorRevoke_BlocksSubsequentRequests() external {
        _performDeposit(alice, 100 * DECIMALS);

        // Approve and then revoke bob
        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.prank(alice);
        vault.setOperator(bob, false);
        assertFalse(vault.isOperator(alice, bob), "bob should no longer be operator");

        // Bob's request should now fail
        vm.prank(bob);
        vm.expectRevert(IOllaVault.OllaVault__Unauthorized.selector);
        vault.requestRedeem(50 * DECIMALS, alice, alice);

        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "alice shares unchanged");
    }
}
