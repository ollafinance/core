// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @notice Minimal OllaVault V2 stub for upgrade tests.
contract OllaVaultV2Stub is OllaVault {
    function vaultVersion() external pure returns (uint256) {
        return 2;
    }
}

/// @title OllaVaultGuardsTest
/// @notice Tests covering untested branches and functions in OllaVault.sol.
contract OllaVaultGuardsTest is Test {
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
    MockOllaGovernance internal governance;
    address internal alice;
    address internal bob;
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
        governance = new MockOllaGovernance();
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 0, 5_000, address(governance), rewardsAccumulator, address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), address(governance));

        vm.prank(address(governance));
        core.setVault(address(vault));

        vm.prank(address(governance));
        core.unpause();

        vm.prank(address(governance));
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
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
        vault.finalizeWithdrawals(assets, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    UNTESTED VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_CoreView_ReturnsExpectedAddress() external view {
        assertEq(vault.core(), address(core), "core() should return OllaCore address");
    }

    function test_SafetyModuleView_ReturnsExpectedAddress() external view {
        assertEq(vault.safetyModule(), address(safetyModule), "safetyModule() should return safety module address");
    }

    /*//////////////////////////////////////////////////////////////
                    UUPS UPGRADE (_authorizeUpgrade)
    //////////////////////////////////////////////////////////////*/

    function test_AuthorizeUpgrade_SuccessfulUpgrade() external {
        OllaVaultV2Stub newImpl = new OllaVaultV2Stub();

        vm.prank(address(governance));
        vault.upgradeToAndCall(address(newImpl), "");

        assertEq(OllaVaultV2Stub(address(vault)).vaultVersion(), 2, "vault should be upgraded to v2");
    }

    function test_RevertWhen_AuthorizeUpgrade_ZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "newImplementation"));
        vm.prank(address(governance));
        vault.upgradeToAndCall(address(0), "");
    }

    function test_RevertWhen_AuthorizeUpgrade_NonOwner() external {
        OllaVaultV2Stub newImpl = new OllaVaultV2Stub();
        vm.expectRevert();
        vm.prank(alice);
        vault.upgradeToAndCall(address(newImpl), "");
    }

    /*//////////////////////////////////////////////////////////////
                  INITIALIZE ZERO-ADDRESS GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_InitializeZeroAsset() external {
        OllaVault impl = new OllaVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        OllaVault freshVault = OllaVault(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "asset_"));
        freshVault.initialize(
            MockAztec(address(0)), stAztec, address(withdrawalQueue), address(core), address(governance)
        );
    }

    function test_RevertWhen_InitializeZeroStAztec() external {
        OllaVault impl = new OllaVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        OllaVault freshVault = OllaVault(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "stAztec_"));
        freshVault.initialize(asset, StAztec(address(0)), address(withdrawalQueue), address(core), address(governance));
    }

    function test_RevertWhen_InitializeZeroWithdrawalQueue() external {
        OllaVault impl = new OllaVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        OllaVault freshVault = OllaVault(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "withdrawalQueue_"));
        freshVault.initialize(asset, stAztec, address(0), address(core), address(governance));
    }

    function test_RevertWhen_InitializeZeroCore() external {
        OllaVault impl = new OllaVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        OllaVault freshVault = OllaVault(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "core_"));
        freshVault.initialize(asset, stAztec, address(withdrawalQueue), address(0), address(governance));
    }

    function test_RevertWhen_InitializeZeroGovernance() external {
        OllaVault impl = new OllaVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        OllaVault freshVault = OllaVault(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "governanceContract_"));
        freshVault.initialize(asset, stAztec, address(withdrawalQueue), address(core), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        MINT GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Mint_SafetyModulePaused() external {
        safetyModule.pause();

        asset.mint(alice, 100 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 100 * DECIMALS);

        vm.expectRevert(IOllaVault.OllaVault__SafetyModulePaused.selector);
        vm.prank(alice);
        vault.mint(10 * DECIMALS, alice);
    }

    function test_RevertWhen_Mint_DepositCapExceeded() external {
        // Mock safety module to return false for checkDepositAllowed
        vm.mockCall(
            address(safetyModule), abi.encodeWithSelector(ISafetyModule.checkDepositAllowed.selector), abi.encode(false)
        );

        asset.mint(alice, 100 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 100 * DECIMALS);

        vm.expectRevert();
        vm.prank(alice);
        vault.mint(10 * DECIMALS, alice);
    }

    /*//////////////////////////////////////////////////////////////
              REQUEST REDEEM / TRANSFER TO CORE / FINALIZE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestRedeem_ZeroController() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "controller"));
        vm.prank(alice);
        vault.requestRedeem(shares, address(0), alice);
    }

    function test_RevertWhen_TransferToCore_ZeroAmount() external {
        vm.expectRevert(IOllaVault.OllaVault__InvalidAmount.selector);
        vm.prank(address(core));
        vault.transferToCore(0);
    }

    function test_RevertWhen_TransferToCore_ExceedsBuffer() external {
        _performDeposit(alice, 10 * DECIMALS);
        uint256 buffered = vault.bufferedAssets();

        vm.expectRevert(
            abi.encodeWithSelector(IOllaVault.OllaVault__InsufficientBuffer.selector, buffered + 1, buffered)
        );
        vm.prank(address(core));
        vault.transferToCore(buffered + 1);
    }

    function test_FinalizeWithdrawals_ZeroAvailableAssets_ReturnsZero() external {
        vm.prank(address(core));
        (uint256 amount, uint256 count) = vault.finalizeWithdrawals(0, type(uint256).max);
        assertEq(amount, 0, "finalized amount should be 0 for zero available");
        assertEq(count, 0, "finalized count should be 0 for zero available");
    }

    function test_FinalizeWithdrawals_ZeroQueued_ReturnsZero() external {
        // No pending withdrawal requests exist
        vm.prank(address(core));
        (uint256 amount, uint256 count) = vault.finalizeWithdrawals(10 * DECIMALS, type(uint256).max);
        assertEq(amount, 0, "finalized amount should be 0 when no queued requests");
        assertEq(count, 0, "finalized count should be 0 when no queued requests");
    }

    function test_RevertWhen_FinalizeWithdrawals_InsufficientBufferedAssets() external {
        // Deposit and request redeem to create a pending request
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        _performRequestRedeem(alice, shares);

        // Transfer most buffer to core so finalization cannot be covered
        uint256 buffered = vault.bufferedAssets();
        if (buffered > 1) {
            vm.prank(address(core));
            vault.transferToCore(buffered - 1);
        }

        // Available is large but buffered is tiny — mock queue finalization to use more than available buffer
        // The mock queue's finalizeWithdrawals uses the stored request amounts
        // Since we requested 10 * DECIMALS worth but only have 1 wei buffered:
        vm.expectRevert();
        vm.prank(address(core));
        vault.finalizeWithdrawals(10 * DECIMALS, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                      GUARDIAN PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_Pause_ViaGuardianRole() external {
        vm.prank(address(governance));
        vault.pause();
        assertTrue(vault.paused(), "vault should be paused");
    }

    function test_Unpause_ViaGuardianRole() external {
        vm.prank(address(governance));
        vault.pause();
        assertTrue(vault.paused(), "vault should be paused");

        vm.prank(address(governance));
        vault.unpause();
        assertFalse(vault.paused(), "vault should be unpaused");
    }

    /*//////////////////////////////////////////////////////////////
                          OTHER GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RecoverStAztec_ZeroAmount() external {
        vm.expectRevert(IOllaVault.OllaVault__InvalidAmount.selector);
        vm.prank(address(governance));
        vault.recoverStAztec(alice, 0);
    }

    function test_MaxMint_SafetyModulePaused_ReturnsZero() external {
        safetyModule.pause();
        assertEq(vault.maxMint(alice), 0, "maxMint should return 0 when safety module is paused");
    }

    function test_MaxMint_CapReached_ReturnsZero() external {
        // Mock depositCap to be 0 (or very small) so current >= cap
        vm.mockCall(address(safetyModule), abi.encodeWithSelector(ISafetyModule.depositCap.selector), abi.encode(0));

        assertEq(vault.maxMint(alice), 0, "maxMint should return 0 when cap is reached");
    }

    function test_RevertWhen_Deposit_ZeroRecipient() external {
        asset.mint(alice, 10 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 10 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "recipient"));
        vm.prank(alice);
        vault.deposit(10 * DECIMALS, address(0), 0);
    }

    function test_RevertWhen_Deposit_ZeroAssets() external {
        vm.expectRevert(IOllaVault.OllaVault__InvalidAmount.selector);
        vm.prank(alice);
        vault.deposit(0, alice, 0);
    }

    function test_RevertWhen_ClaimWithdrawal_AssetsMismatch() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        uint256 requestId = _performRequestRedeem(alice, shares);
        _finalizeAll(10 * DECIMALS);

        // Mock claimWithdrawal to return a different amount
        vm.mockCall(
            address(withdrawalQueue),
            abi.encodeWithSelector(MockWithdrawalQueue.claimWithdrawal.selector, requestId),
            abi.encode(uint256(1))
        );

        vm.expectRevert();
        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    function test_RevertWhen_ReconcileBufferedAssets_ActualBelowFinalizedUnclaimed() external {
        // Deposit and create a request that gets finalized (builds _finalizedUnclaimedAssets)
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        _performRequestRedeem(alice, shares);
        _finalizeAll(10 * DECIMALS);

        // Now _finalizedUnclaimedAssets should be ~10 * DECIMALS
        // Remove tokens from vault to make actual < _finalizedUnclaimedAssets
        uint256 vaultBalance = asset.balanceOf(address(vault));
        vm.prank(address(vault));
        asset.transfer(address(1), vaultBalance);

        vm.expectRevert();
        vm.prank(address(governance));
        vault.reconcileBufferedAssets();
    }

    /*//////////////////////////////////////////////////////////////
                       PERMIT FLOW REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestRedeemWithPermit_InvalidSignature() external {
        _performDeposit(alice, 10 * DECIMALS);

        // Call with invalid permit signature
        vm.expectRevert();
        vm.prank(alice);
        vault.requestRedeemWithPermit(
            10 * DECIMALS, alice, block.timestamp + 1, 27, bytes32(uint256(1)), bytes32(uint256(2))
        );
    }

    function test_RevertWhen_InstantRedeemWithPermit_InvalidSignature() external {
        _performDeposit(alice, 10 * DECIMALS);

        // Call with invalid permit signature
        vm.expectRevert();
        vm.prank(alice);
        vault.instantRedeemWithPermit(
            10 * DECIMALS, alice, 0, block.timestamp + 1, 27, bytes32(uint256(1)), bytes32(uint256(2))
        );
    }
}
