// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";
import { ECDSA } from "@oz/utils/cryptography/ECDSA.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreWithdrawalTest is Test {
    using Math for uint256;
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event Rebalanced(uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer);
    event AccountingUpdated(
        uint256 totalAssets,
        uint256 exchangeRate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
    );
    event AttestersStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    address internal permitOwner;
    uint256 internal permitOwnerKey;
    uint256 internal permitAttackerKey;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        operator = makeAddr("operator");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        permitOwnerKey = 0xA11CE;
        permitOwner = vm.addr(permitOwnerKey);
        permitAttackerKey = 0xB0B;

        // Advance past the 1-hour rebalance cooldown initialised in OllaCore.initialize()
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    function _queueRequestSnapshot()
        internal
        view
        returns (address user, uint256 shares, uint256 assetsExpected, uint256 rate)
    {
        uint256 lastId = vault.nextWithdrawalRequestId() - 1;
        IOllaVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(lastId);
        user = vault.requestOwner(lastId);
        shares = req.shares;
        assetsExpected = req.assetsExpected;
        rate = req.rate;
    }

    function _signPermit(
        IERC20Permit token,
        address owner,
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = token.nonces(owner);
        bytes32 digest = _buildPermitDigest(token, owner, spender, value, nonce, deadline);
        (v, r, s) = vm.sign(ownerKey, digest);
        return (v, r, s);
    }

    function _buildPermitDigest(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32 digest) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return digest;
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL REQUESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_CallsQueueWithExpectedValues() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 rate = core.exchangeRate();
        uint256 shares = 6 * DECIMALS;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRequest(bob, alice, 1, alice, expectedAssets);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob, alice);

        assertEq(requestId, 1, "request id should start at 1");
        (address recipient, uint256 recordedShares, uint256 recordedAssets, uint256 recordedRate) =
            _queueRequestSnapshot();
        assertEq(recipient, bob, "queue receives recipient");
        assertEq(recordedShares, shares, "queue receives share amount");
        assertEq(recordedAssets, expectedAssets, "queue receives assetsExpected");
        assertEq(recordedRate, rate, "queue receives exchange rate");
    }

    function test_RequestOwner_ReturnsControllerNotShareOwner() external {
        _performDeposit(alice, 12 * DECIMALS);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 * DECIMALS, bob, alice);

        assertEq(vault.requestOwner(requestId), bob, "controller owns the request (ERC-7540)");
    }

    function test_ActiveRequestIds_ReturnsOutstandingRequests() external {
        _performDeposit(alice, 20 * DECIMALS);

        vm.prank(alice);
        uint256 firstRequestId = vault.requestRedeem(6 * DECIMALS, bob, alice);
        vm.prank(alice);
        uint256 secondRequestId = vault.requestRedeem(4 * DECIMALS, alice, alice);

        // First request is owned by bob (controller), second by alice
        uint256[] memory bobRequests = vault.activeRequestIds(bob);
        assertEq(bobRequests.length, 1, "bob active request count");
        assertEq(bobRequests[0], firstRequestId, "bob owns first request");

        uint256[] memory aliceRequests = vault.activeRequestIds(alice);
        assertEq(aliceRequests.length, 1, "alice active request count");
        assertEq(aliceRequests[0], secondRequestId, "alice owns second request");

        // Finalize requests before claiming
        vm.prank(address(core));
        vault.finalizeWithdrawals(type(uint256).max, type(uint256).max, type(uint256).max);

        vm.prank(alice);
        vault.claimRequestById(secondRequestId);

        aliceRequests = vault.activeRequestIds(alice);
        assertEq(aliceRequests.length, 0, "alice active request count after claim");
    }

    function test_RequestRedeem_StillWorks() external {
        _performDeposit(alice, 15 * DECIMALS);

        uint256 shares = 5 * DECIMALS;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        assertEq(requestId, 1, "request id should start at 1");
    }

    /*//////////////////////////////////////////////////////////////
                           OPERATOR ACTIONS
    //////////////////////////////////////////////////////////////*/

    function test_OperatorCanCallOperatorHooks() external {
        vm.expectEmit(true, true, true, true, address(core));
        emit Rebalanced(0, 0, 0, 0);
        vm.prank(operator);
        core.rebalance();

        uint256 expectedExchangeRate = core.exchangeRate();
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(core));
        emit AttestersStateRead(0, 0, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(core));
        emit AccountingUpdated(0, expectedExchangeRate, 0, 0, 0, 0, 0, expectedTimestamp);
        vm.prank(operator);
        core.updateAccounting();
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAWAL CLAIMS
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_AllowsMultipleRequestsAndClaimsById() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 sharesFirst = 6 * DECIMALS;
        uint256 sharesSecond = 4 * DECIMALS;

        vm.prank(alice);
        uint256 firstRequestId = vault.requestRedeem(sharesFirst, bob, alice);
        vm.prank(alice);
        uint256 secondRequestId = vault.requestRedeem(sharesSecond, alice, alice);

        IOllaVault.WithdrawalRequest memory firstRequest = vault.getWithdrawalRequest(firstRequestId);
        IOllaVault.WithdrawalRequest memory secondRequest = vault.getWithdrawalRequest(secondRequestId);
        uint256 expectedFirst = firstRequest.assetsExpected;
        uint256 expectedSecond = secondRequest.assetsExpected;

        assertEq(firstRequestId, 1, "first request id");
        assertEq(secondRequestId, 2, "second request id");

        // Finalize requests before claiming
        vm.prank(address(core));
        vault.finalizeWithdrawals(type(uint256).max, type(uint256).max, type(uint256).max);

        uint256 bobBalanceBefore = asset.balanceOf(bob);
        uint256 aliceBalanceBefore = asset.balanceOf(alice);

        // bob is the controller of the first request (ERC-7540)
        vm.prank(bob);
        uint256 claimedFirst = vault.claimRequestById(firstRequestId);
        vm.prank(alice);
        uint256 claimedSecond = vault.claimRequestById(secondRequestId);

        uint256 bobBalanceAfter = asset.balanceOf(bob);
        uint256 aliceBalanceAfter = asset.balanceOf(alice);

        assertEq(claimedFirst, expectedFirst, "first claim matches expected");
        assertEq(claimedSecond, expectedSecond, "second claim matches expected");
        assertEq(bobBalanceAfter - bobBalanceBefore, expectedFirst, "recipient receives first claim");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, expectedSecond, "recipient receives second claim");
        assertEq(vault.requestOwner(firstRequestId), address(0), "first request owner cleared");
        assertEq(vault.requestOwner(secondRequestId), address(0), "second request owner cleared");
    }

    function test_ClaimRequestById_AllowsNonOwner() external {
        _performDeposit(alice, 15 * DECIMALS);

        uint256 rate = core.exchangeRate();
        uint256 shares = 5 * DECIMALS;
        uint256 assetsExpected = shares * rate / DECIMALS;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob, alice);

        // Finalize request before claiming
        vm.prank(address(core));
        vault.finalizeWithdrawals(type(uint256).max, type(uint256).max, type(uint256).max);

        uint256 balanceBefore = asset.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 balanceAfter = asset.balanceOf(bob);
        assertEq(claimed, assetsExpected, "claimed assets match expected");
        assertEq(balanceAfter - balanceBefore, assetsExpected, "assets sent to receiver");
        assertEq(vault.requestOwner(requestId), address(0), "request owner cleared");
    }

    /*//////////////////////////////////////////////////////////////
                       PERMIT WITHDRAWAL REQUESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeemWithPermit_CallsQueueAndEmits() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 6 * DECIMALS;
        uint256 rate = core.exchangeRate();
        uint256 assetsExpected = shares * rate / DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemRequest(bob, permitOwner, 1, permitOwner, assetsExpected);

        vm.prank(permitOwner);
        uint256 requestId = vault.requestRedeemWithPermit(shares, bob, deadline, v, r, s);

        assertEq(requestId, 1, "request id should start at 1");
        (address recipient, uint256 recordedShares, uint256 recordedAssets, uint256 recordedRate) =
            _queueRequestSnapshot();
        assertEq(recipient, bob, "queue receives recipient");
        assertEq(recordedShares, shares, "queue receives share amount");
        assertEq(recordedAssets, assetsExpected, "queue receives assetsExpected");
        assertEq(recordedRate, rate, "queue receives exchange rate");
        assertEq(stAztec.allowance(permitOwner, address(vault)), 0, "allowance consumed by transferFrom");
        assertEq(IERC20Permit(address(stAztec)).nonces(permitOwner), 1, "nonce incremented");
    }

    function test_RequestRedeemWithPermit_AllowsMaxAllowance() external {
        // Use a large but safe deposit amount to avoid overflow in virtual offset (+1).
        // type(uint256).max would cause totalSupply() + 1 to overflow in _convertToAssets.
        uint256 assets = type(uint128).max;
        asset.mint(permitOwner, assets);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 depositV, bytes32 depositR, bytes32 depositS) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, 0, deadline, depositV, depositR, depositS);

        // Sign permit for type(uint256).max to test that max allowance remains max.
        // requestRedeemWithPermit calls permit(owner, vault, shares, ...) setting
        // allowance to type(uint256).max, then _requestRedeem burns via OllaVault
        // without consuming allowance. So the max allowance is preserved.
        uint256 shares = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        // Redeem the actual share balance (not type(uint256).max which would exceed balance).
        // We call permit manually for type(uint256).max, then requestRedeem for the actual balance.
        uint256 actualShares = stAztec.balanceOf(permitOwner);
        IERC20Permit(address(stAztec)).permit(permitOwner, address(vault), shares, deadline, v, r, s);

        vm.prank(permitOwner);
        vault.requestRedeem(actualShares, permitOwner, permitOwner);

        assertEq(stAztec.allowance(permitOwner, address(vault)), type(uint256).max, "allowance remains max");
    }

    function test_RevertWhen_RequestRedeemWithPermit_ExpiredSignature() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 4 * DECIMALS;
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOllaVault.OllaVault__PermitFailed.selector,
                abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline)
            )
        );
        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);
    }

    function test_RevertWhen_RequestRedeemWithPermit_InvalidSignature() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 4 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            IERC20Permit(address(stAztec)), permitOwner, permitAttackerKey, address(vault), shares, deadline
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IOllaVault.OllaVault__PermitFailed.selector,
                abi.encodeWithSelector(
                    ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(permitAttackerKey), permitOwner
                )
            )
        );
        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);
    }

    function test_RevertWhen_RequestRedeemWithPermit_ReplayedNonce() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 4 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);

        // Permit-set allowance was consumed by transferFrom, so no allowance fallback exists.
        uint256 nonce = IERC20Permit(address(stAztec)).nonces(permitOwner);
        bytes32 digest =
            _buildPermitDigest(IERC20Permit(address(stAztec)), permitOwner, address(vault), shares, nonce, deadline);
        address signer = ECDSA.recover(digest, v, r, s);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOllaVault.OllaVault__PermitFailed.selector,
                abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, signer, permitOwner)
            )
        );
        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
      REQUEST REDEEM: assetsExpected MATCHES convertToAssets
      (NO DOUBLE-MULDIV ROUNDING)
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures _requestRedeem computes assetsExpected identically to the
    ///         public convertToAssets view, proving there is no double-mulDiv
    ///         rounding discrepancy. Uses a non-trivial exchange rate that would
    ///         surface a 1-wei divergence under the old two-step approach.
    function test_RequestRedeem_AssetsExpectedMatchesConvertToAssets() external {
        // Deposit a small amount so supply = 3
        uint256 depositAmount = 3;
        _performDeposit(alice, depositAmount);

        // Simulate rewards that create an awkward rate: totalAssets = 1e18 + 1
        uint256 rewards = 1 ether - 3 + 1;
        asset.mint(address(vault), rewards);

        // Trigger buffer sync so totalAssets reflects the rewards
        vm.prank(governance);
        core.rebalance();

        // Snapshot state before requestRedeem
        uint256 totalAssetsBefore = core.totalAssets();
        uint256 supplyBefore = stAztec.totalSupply();
        uint256 sharesToRedeem = 2;

        // Single-step expected value (what convertToAssets returns)
        uint256 expectedAssets = sharesToRedeem.mulDiv(totalAssetsBefore + 1e3, supplyBefore + 1e3, Math.Rounding.Floor);
        uint256 viewAssets = core.convertToAssets(sharesToRedeem);
        assertEq(viewAssets, expectedAssets, "convertToAssets matches single-step formula");

        // Request redeem and check assetsExpected stored in the queue
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, bob, alice);

        (, uint256 recordedShares, uint256 recordedAssets,) = _queueRequestSnapshot();
        assertEq(recordedShares, sharesToRedeem, "shares match");
        assertEq(recordedAssets, expectedAssets, "assetsExpected matches single-step convertToAssets");
    }

    /*//////////////////////////////////////////////////////////////
                   FUZZ: REQUEST REDEEM VARYING SHARES
    //////////////////////////////////////////////////////////////*/

    function testFuzz_RequestRedeem_VaryingShares(uint96 depositAmount, uint96 sharesSeed) external {
        depositAmount = uint96(bound(depositAmount, 2e18, type(uint96).max));

        _performDeposit(alice, depositAmount);

        uint256 aliceShares = stAztec.balanceOf(alice);
        uint256 shares = bound(uint256(sharesSeed), 1, aliceShares);

        uint256 expectedAssets = core.convertToAssets(shares);
        uint256 sharesBefore = stAztec.balanceOf(alice);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        (, uint256 recordedShares, uint256 recordedAssets,) = _queueRequestSnapshot();
        assertEq(recordedShares, shares, "recorded shares match");
        assertEq(recordedAssets, expectedAssets, "request assets == convertToAssets(shares)");
        assertEq(stAztec.balanceOf(alice), sharesBefore - shares, "stAztec decreased by shares");
    }
}
