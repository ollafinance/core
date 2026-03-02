// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaVaultOperatorTest is Test {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

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
    address internal charlie;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
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

    function _performRequestRedeem(address owner, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
        return requestId;
    }

    function _finalizeAll(uint256 assets) internal {
        vm.prank(address(core));
        vault.finalizeWithdrawals(assets);
    }

    /*//////////////////////////////////////////////////////////////
                        SET OPERATOR TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice setOperator approves an operator.
    function test_SetOperator_ApprovesOperator() external {
        vm.prank(alice);
        vault.setOperator(bob, true);

        assertTrue(vault.isOperator(alice, bob), "bob should be operator for alice");
    }

    /// @notice setOperator revokes an operator.
    function test_SetOperator_RevokesOperator() external {
        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(vault.isOperator(alice, bob), "bob approved");

        vm.prank(alice);
        vault.setOperator(bob, false);
        assertFalse(vault.isOperator(alice, bob), "bob revoked");
    }

    /// @notice setOperator emits OperatorSet event.
    function test_SetOperator_EmitsEvent() external {
        vm.expectEmit(true, true, true, true, address(vault));
        emit OperatorSet(alice, bob, true);

        vm.prank(alice);
        vault.setOperator(bob, true);
    }

    /// @notice setOperator reverts when setting self as operator.
    function test_RevertWhen_SetOperator_SelfApproval() external {
        vm.expectRevert(IOllaVault.OllaVault__InvalidParameter.selector);
        vm.prank(alice);
        vault.setOperator(alice, true);
    }

    /*//////////////////////////////////////////////////////////////
                         IS OPERATOR TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice isOperator returns false by default.
    function test_IsOperator_DefaultFalse() external view {
        assertFalse(vault.isOperator(alice, bob), "default is false");
    }

    /*//////////////////////////////////////////////////////////////
              OPERATOR INTEGRATION WITH REQUEST FLOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Approved operator can call requestRedeem on behalf of owner.
    function test_Operator_CanRequestRedeemOnBehalf() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);

        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        assertGt(requestId, 0, "request created");
        assertEq(stAztec.balanceOf(alice), 0, "shares burned from alice");
    }

    /// @notice Approved operator can claim via claimRequestById.
    function test_Operator_CanClaimRequestById() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        uint256 requestId = _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        uint256 assets = vault.claimRequestById(requestId);

        assertEq(assets, depositAmount, "assets claimed");
    }

    /// @notice Non-operator reverts on requestRedeem.
    function test_RevertWhen_Unauthorized_RequestRedeem() external {
        _performDeposit(alice, 10 * DECIMALS);

        vm.expectRevert(IOllaVault.OllaVault__Unauthorized.selector);
        vm.prank(bob);
        vault.requestRedeem(10 * DECIMALS, alice, alice);
    }

    /// @notice Non-operator reverts on claimRequestById.
    function test_RevertWhen_Unauthorized_ClaimRequestById() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        uint256 requestId = _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.expectRevert(IOllaVault.OllaVault__Unauthorized.selector);
        vm.prank(bob);
        vault.claimRequestById(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                    REDEEM (SYNC ERC-4626 CLAIM PATH)
    //////////////////////////////////////////////////////////////*/

    /// @notice Full lifecycle: deposit → requestRedeem → finalize → redeem.
    function test_Redeem_ClaimsFinalized() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, depositAmount, "assets returned");
        assertEq(asset.balanceOf(alice), depositAmount, "alice received tokens");
    }

    /// @notice redeem sends assets to the specified receiver.
    function test_Redeem_SendsToReceiver() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, charlie, alice);

        assertEq(assets, depositAmount, "assets returned");
        assertEq(asset.balanceOf(charlie), depositAmount, "charlie received tokens");
        assertEq(asset.balanceOf(alice), 0, "alice did not receive tokens");
    }

    /// @notice Approved operator can call redeem for controller.
    function test_Redeem_OperatorCanRedeem() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        uint256 assets = vault.redeem(shares, bob, alice);

        assertEq(assets, depositAmount, "assets returned");
        assertEq(asset.balanceOf(bob), depositAmount, "bob received tokens");
    }

    /// @notice redeem reverts on zero receiver.
    function test_RevertWhen_Redeem_ZeroReceiver() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "receiver"));
        vm.prank(alice);
        vault.redeem(shares, address(0), alice);
    }

    /// @notice redeem reverts when no finalized request matches shares.
    function test_RevertWhen_Redeem_NoMatchingRequest() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__RequestNotFound.selector, 0));
        vm.prank(alice);
        vault.redeem(10 * DECIMALS, alice, alice);
    }

    /// @notice redeem reverts when caller is not controller or operator.
    function test_RevertWhen_Redeem_Unauthorized() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.expectRevert(IOllaVault.OllaVault__Unauthorized.selector);
        vm.prank(bob);
        vault.redeem(shares, bob, alice);
    }
}
