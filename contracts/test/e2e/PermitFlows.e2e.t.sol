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

/// @title PermitFlowsE2ETest
/// @notice Phase 5 E2E: validates ERC-2612 permit-based deposit and redeem request flows.
///         Wires real OllaCore, OllaVault, WithdrawalQueue, SafetyModule
///         with MockAccountingStakingManager and MockRewardsAccumulator.
contract PermitFlowsE2ETest is Test {
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

    /// @dev Establishes a baseline rebalance with staking suppressed and zero rewards.
    ///      Replaces the historical pattern of setting a huge `targetBufferedAssets` to
    ///      keep funds in the buffer: `setStakeReturnAmount(0)` toggles the mock's
    ///      `useStakeReturnAmount` flag, which makes both `canStake()` return false and
    ///      `stake()` return 0. The flag is sticky across subsequent rebalances, so
    ///      later rebalances that harvest rewards do not stake the new buffer either.
    function _baselineRebalance() internal {
        stakingManager.setStakeReturnAmount(0);
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
        TEST 5A: DEPOSIT WITH PERMIT — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice A valid ERC-2612 permit enables deposit without prior approve().
    function test_DepositWithPermit_HappyPath() external {
        asset.mint(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(asset), aliceKey, alice, address(vault), 100 * DECIMALS, deadline);

        vm.prank(alice);
        uint256 shares = vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v, r, s);

        assertEq(shares, 100 * DECIMALS, "alice should receive 100e18 shares at 1:1 rate");
        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "alice stAztec balance should be 100e18");
        assertEq(asset.balanceOf(address(vault)), 100 * DECIMALS, "vault should hold 100e18 assets");
        assertEq(asset.allowance(alice, address(vault)), 0, "allowance should be 0 (permit consumed exactly)");
        assertEq(IERC20Permit(address(asset)).nonces(alice), 1, "alice nonce should be 1");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 5B: DEPOSIT WITH PERMIT — EXPIRED DEADLINE REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice An expired deadline causes the permit to fail, reverting the deposit.
    function test_DepositWithPermit_ExpiredDeadline_Reverts() external {
        asset.mint(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp - 1; // already expired
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(asset), aliceKey, alice, address(vault), 100 * DECIMALS, deadline);

        vm.prank(alice);
        vm.expectRevert(); // OllaVault__PermitFailed wrapping ERC2612ExpiredSignature
        vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v, r, s);

        // No state changes
        assertEq(stAztec.balanceOf(alice), 0, "no shares should be minted");
        assertEq(asset.balanceOf(alice), 100 * DECIMALS, "alice should still have her assets");
        assertEq(IERC20Permit(address(asset)).nonces(alice), 0, "nonce should not be consumed");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 5C: DEPOSIT WITH PERMIT — WRONG SIGNER REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Signing with a different key than the owner causes permit failure.
    function test_DepositWithPermit_WrongSigner_Reverts() external {
        asset.mint(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;
        // Sign with bobKey but owner is alice
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(asset), bobKey, alice, address(vault), 100 * DECIMALS, deadline);

        vm.prank(alice);
        vm.expectRevert(); // OllaVault__PermitFailed wrapping ERC2612InvalidSigner
        vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v, r, s);

        // No state changes
        assertEq(stAztec.balanceOf(alice), 0, "no shares should be minted");
        assertEq(asset.balanceOf(alice), 100 * DECIMALS, "alice should still have her assets");
        assertEq(IERC20Permit(address(asset)).nonces(alice), 0, "nonce should not be consumed");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 5D: DEPOSIT WITH PERMIT — SLIPPAGE PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice minSharesOut slippage check works in the permit deposit flow:
    ///         reverts when shares < minSharesOut, succeeds with exact minimum.
    function test_DepositWithPermit_SlippageProtection() external {
        // --- Setup: create rate > 1:1 using carol as initial depositor ---
        address carol = makeAddr("carol");
        _performDeposit(carol, 100 * DECIMALS);
        _baselineRebalance();

        stakingManager.setHarvestedRewards(10 * DECIMALS);
        stakingManager.setClaimableRewards(1);
        _warpPastCooldown();
        _fullRebalance();

        uint256 newRate = core.exchangeRate();
        assertGt(newRate, 1e18, "rate should be > 1e18 after rewards");

        // --- alice deposit with permit: minSharesOut too high → SlippageExceeded ---
        asset.mint(alice, 100 * DECIMALS);

        uint256 expectedShares = core.convertToShares(100 * DECIMALS);
        assertLt(expectedShares, 100 * DECIMALS, "expected shares should be < 100e18 at rate > 1");

        // Use type(uint256).max deadline to avoid Solidity optimizer caching block.timestamp
        // from before vm.warp (the optimizer may evaluate TIMESTAMP once per function entry).
        uint256 deadline = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(asset), aliceKey, alice, address(vault), 100 * DECIMALS, deadline);

        // minSharesOut = 100e18 but actual shares < 100e18 → revert
        vm.expectRevert(
            abi.encodeWithSelector(IOllaVault.OllaVault__SlippageExceeded.selector, expectedShares, 100 * DECIMALS)
        );
        vm.prank(alice);
        vault.depositWithPermit(100 * DECIMALS, alice, 100 * DECIMALS, deadline, v, r, s);

        // Entire tx reverted → nonce unchanged, no side effects
        assertEq(IERC20Permit(address(asset)).nonces(alice), 0, "nonce should still be 0 after revert");
        assertEq(asset.balanceOf(alice), 100 * DECIMALS, "alice should still have all assets");
        assertEq(stAztec.balanceOf(alice), 0, "no shares should be minted");

        // --- Same signature works with acceptable slippage (nonce unchanged after revert) ---
        vm.prank(alice);
        uint256 shares = vault.depositWithPermit(100 * DECIMALS, alice, expectedShares, deadline, v, r, s);

        assertEq(shares, expectedShares, "alice should receive expectedShares");
        assertLt(shares, 100 * DECIMALS, "alice should receive fewer than 100e18 shares");
        assertEq(IERC20Permit(address(asset)).nonces(alice), 1, "nonce should be 1 after successful deposit");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 5E: REQUEST REDEEM WITH PERMIT — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice A valid permit on stAztec enables requestRedeem without prior approve().
    function test_RequestRedeemWithPermit_HappyPath() external {
        // --- Setup: alice deposits 100e18 → 100e18 stAztec ---
        _performDeposit(alice, 100 * DECIMALS);

        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "pre: alice should have 100e18 shares");

        // --- Sign permit on stAztec for 50e18 shares ---
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(stAztec), aliceKey, alice, address(vault), 50 * DECIMALS, deadline);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeemWithPermit(50 * DECIMALS, alice, deadline, v, r, s);

        assertGt(requestId, 0, "requestId should be > 0");
        assertEq(stAztec.balanceOf(alice), 50 * DECIMALS, "alice should have 50e18 shares remaining");
        assertEq(IERC20Permit(address(stAztec)).nonces(alice), 1, "stAztec nonce should be 1");
        // Permit-set allowance is consumed by safeTransferFrom in the permit path.
        assertEq(stAztec.allowance(alice, address(vault)), 0, "stAztec allowance consumed by transferFrom");

        // Verify withdrawal request was created
        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(requestId);
        assertEq(req.shares, 50 * DECIMALS, "request should be for 50e18 shares");
        assertFalse(req.finalized, "request should not be finalized yet");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 5F: REQUEST REDEEM WITH PERMIT — REPLAY PREVENTED
    //////////////////////////////////////////////////////////////*/

    /// @notice Replaying the same permit signature after nonce increment reverts.
    ///         The first call consumes the permit-set allowance via transferFrom,
    ///         so the second call has no allowance fallback.
    function test_RequestRedeemWithPermit_ReplayPrevented() external {
        // --- Setup: alice deposits 100e18 → 100e18 stAztec ---
        _performDeposit(alice, 100 * DECIMALS);

        // --- Sign permit for 30e18 stAztec ---
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(stAztec), aliceKey, alice, address(vault), 30 * DECIMALS, deadline);

        // --- First call: succeeds (permit-set allowance consumed by transferFrom) ---
        vm.prank(alice);
        uint256 requestId = vault.requestRedeemWithPermit(30 * DECIMALS, alice, deadline, v, r, s);

        assertGt(requestId, 0, "first call should succeed");
        assertEq(stAztec.balanceOf(alice), 70 * DECIMALS, "alice should have 70e18 shares after first request");
        assertEq(IERC20Permit(address(stAztec)).nonces(alice), 1, "nonce should be 1 after first call");
        assertEq(stAztec.allowance(alice, address(vault)), 0, "allowance consumed by transferFrom");

        // --- Second call: same (v, r, s) → reverts (nonce consumed, no allowance fallback) ---
        vm.prank(alice);
        vm.expectRevert(); // OllaVault__PermitFailed (nonce mismatch, no allowance)
        vault.requestRedeemWithPermit(30 * DECIMALS, alice, deadline, v, r, s);

        // No state changes from failed replay
        assertEq(stAztec.balanceOf(alice), 70 * DECIMALS, "alice shares should remain 70e18");
        assertEq(IERC20Permit(address(stAztec)).nonces(alice), 1, "nonce should still be 1");
    }

    /*//////////////////////////////////////////////////////////////
        TEST 5G: DEPOSIT WITH PERMIT — FRONTRUN APPROVE DOCUMENTED
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates frontrun protection: when an attacker frontruns the permit
    ///         signature, the vault's try/catch detects that the allowance is already
    ///         sufficient and proceeds with the deposit instead of reverting.
    function test_DepositWithPermit_FrontrunProtection() external {
        asset.mint(alice, 100 * DECIMALS);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(address(asset), aliceKey, alice, address(vault), 100 * DECIMALS, deadline);

        // --- Step 1: Attacker calls asset.permit() directly with alice's signature ---
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        IERC20Permit(address(asset)).permit(alice, address(vault), 100 * DECIMALS, deadline, v, r, s);

        // Attacker set the allowance, nonce incremented
        assertEq(asset.allowance(alice, address(vault)), 100 * DECIMALS, "allowance should be set by attacker");
        assertEq(IERC20Permit(address(asset)).nonces(alice), 1, "nonce should be 1 after attacker's permit");

        // --- Step 2: alice's depositWithPermit succeeds despite frontrun ---
        //     The permit call fails (nonce consumed) but the catch block sees
        //     sufficient allowance and falls through to _deposit().
        vm.prank(alice);
        uint256 shares = vault.depositWithPermit(100 * DECIMALS, alice, 0, deadline, v, r, s);

        assertEq(shares, 100 * DECIMALS, "alice should receive 100e18 shares despite frontrun");
        assertEq(stAztec.balanceOf(alice), 100 * DECIMALS, "alice stAztec balance should be 100e18");
        assertEq(asset.balanceOf(address(vault)), 100 * DECIMALS, "vault should hold 100e18 assets");
        assertEq(asset.allowance(alice, address(vault)), 0, "allowance should be consumed by deposit");
    }
}
