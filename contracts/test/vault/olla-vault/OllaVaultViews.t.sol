// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { IERC7540Operator, IERC7540Redeem } from "@forge-std/interfaces/IERC7540.sol";
import { IERC7575 } from "@forge-std/interfaces/IERC7575.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaVaultViewsTest is Test {
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

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
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
        vault.finalizeWithdrawals(assets, type(uint256).max, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW PROXY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice asset() returns the underlying asset address.
    function test_Asset_ReturnsCorrectAddress() external view {
        assertEq(vault.asset(), address(asset), "asset address");
    }

    /// @notice share() returns the stAztec address.
    function test_Share_ReturnsStAztecAddress() external view {
        assertEq(vault.share(), address(stAztec), "share address");
    }

    /// @notice totalAssets() delegates to core.
    function test_TotalAssets_DelegatesToCore() external {
        _performDeposit(alice, 50 * DECIMALS);

        assertEq(vault.totalAssets(), core.totalAssets(), "totalAssets matches core");
    }

    /// @notice convertToShares() delegates to core.
    function test_ConvertToShares_DelegatesToCore() external view {
        uint256 assets = 42 * DECIMALS;
        assertEq(vault.convertToShares(assets), core.convertToShares(assets), "convertToShares matches core");
    }

    /// @notice convertToAssets() delegates to core.
    function test_ConvertToAssets_DelegatesToCore() external view {
        uint256 shares = 42 * DECIMALS;
        assertEq(vault.convertToAssets(shares), core.convertToAssets(shares), "convertToAssets matches core");
    }

    /*//////////////////////////////////////////////////////////////
                      MAX DEPOSIT / MAX MINT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice maxDeposit returns cap minus current total assets.
    function test_MaxDeposit_ReturnsCapMinusCurrent() external {
        uint256 cap = 100 * DECIMALS;
        vm.mockCall(address(safetyModule), abi.encodeWithSelector(ISafetyModule.depositCap.selector), abi.encode(cap));

        _performDeposit(alice, 40 * DECIMALS);

        uint256 expected = cap - vault.totalAssets();
        assertEq(vault.maxDeposit(alice), expected, "maxDeposit = cap - current");
    }

    /// @notice maxDeposit returns zero when vault is paused.
    function test_MaxDeposit_ReturnsZeroWhenPaused() external {
        vm.prank(governance);
        vault.pause();

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit zero when paused");
    }

    /// @notice maxDeposit returns zero when safety module is paused.
    function test_MaxDeposit_ReturnsZeroWhenSafetyModulePaused() external {
        safetyModule.pause();
        safetyModule.mockSetDepositPaused(true);

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit zero when SM paused");
    }

    /// @notice maxDeposit returns zero when deposit cap is reached.
    function test_MaxDeposit_ReturnsZeroWhenCapReached() external {
        uint256 cap = 50 * DECIMALS;
        vm.mockCall(address(safetyModule), abi.encodeWithSelector(ISafetyModule.depositCap.selector), abi.encode(cap));
        // Also mock checkDepositAllowed to not revert at the cap
        vm.mockCall(
            address(safetyModule), abi.encodeWithSelector(ISafetyModule.checkDepositAllowed.selector), abi.encode(true)
        );

        _performDeposit(alice, cap);

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit zero at cap");
    }

    /// @notice maxMint returns shares for remaining cap.
    function test_MaxMint_ReturnsSharesForRemainingCap() external {
        uint256 cap = 100 * DECIMALS;
        vm.mockCall(address(safetyModule), abi.encodeWithSelector(ISafetyModule.depositCap.selector), abi.encode(cap));

        _performDeposit(alice, 40 * DECIMALS);

        uint256 remainingAssets = cap - vault.totalAssets();
        uint256 expected = core.convertToShares(remainingAssets);
        assertEq(vault.maxMint(alice), expected, "maxMint = convertToShares(remaining)");
    }

    /// @notice maxMint returns zero when vault is paused.
    function test_MaxMint_ReturnsZeroWhenPaused() external {
        vm.prank(governance);
        vault.pause();

        assertEq(vault.maxMint(alice), 0, "maxMint zero when paused");
    }

    /*//////////////////////////////////////////////////////////////
                          MAX REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice maxRedeem returns finalized shares.
    function test_MaxRedeem_ReturnsFinalizedShares() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        assertEq(vault.maxRedeem(alice), shares, "maxRedeem returns finalized shares");
    }

    /// @notice maxRedeem ignores pending (unfinalized) requests.
    function test_MaxRedeem_IgnoresPendingRequests() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        _performRequestRedeem(alice, shares);

        assertEq(vault.maxRedeem(alice), 0, "maxRedeem ignores pending");
    }

    /// @notice maxRedeem returns zero when no requests exist.
    function test_MaxRedeem_ReturnsZeroWhenNoneFinalized() external view {
        assertEq(vault.maxRedeem(alice), 0, "maxRedeem zero when no requests");
    }

    /// @notice maxRedeem sums multiple finalized requests.
    function test_MaxRedeem_SumsMultipleFinalizedRequests() external {
        uint256 amount1 = 5 * DECIMALS;
        uint256 amount2 = 7 * DECIMALS;
        uint256 totalDeposit = amount1 + amount2;

        _performDeposit(alice, totalDeposit);

        vm.prank(alice);
        vault.requestRedeem(amount1, alice, alice);
        vm.prank(alice);
        vault.requestRedeem(amount2, alice, alice);

        _finalizeAll(totalDeposit);

        assertEq(vault.maxRedeem(alice), totalDeposit, "maxRedeem sums multiple finalized");
    }

    /// @notice maxRedeem returns zero after all requests are claimed.
    function test_MaxRedeem_ReturnsZeroAfterAllClaimed() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        uint256 requestId = _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);
        assertEq(vault.maxRedeem(alice), shares, "maxRedeem before claim");

        vm.prank(alice);
        vault.claimRequestById(requestId);

        assertEq(vault.maxRedeem(alice), 0, "maxRedeem zero after all claimed");
    }

    /// @notice maxRedeem only counts finalized requests in a partial finalization.
    function test_MaxRedeem_PartialFinalization() external {
        uint256 amount1 = 5 * DECIMALS;
        uint256 amount2 = 7 * DECIMALS;
        uint256 totalDeposit = amount1 + amount2;

        _performDeposit(alice, totalDeposit);

        vm.prank(alice);
        vault.requestRedeem(amount1, alice, alice);
        vm.prank(alice);
        vault.requestRedeem(amount2, alice, alice);

        // Only finalize enough for the first request
        _finalizeAll(amount1);

        assertEq(vault.maxRedeem(alice), amount1, "maxRedeem only counts finalized");
    }

    /// @notice maxRedeem tracks independent counters per user.
    function test_MaxRedeem_MultiUserIndependent() external {
        uint256 aliceAmount = 5 * DECIMALS;
        uint256 bobAmount = 8 * DECIMALS;
        uint256 totalDeposit = aliceAmount + bobAmount;

        _performDeposit(alice, aliceAmount);
        _performDeposit(bob, bobAmount);

        _performRequestRedeem(alice, aliceAmount);
        uint256 bobRequestId = _performRequestRedeem(bob, bobAmount);

        _finalizeAll(totalDeposit);

        assertEq(vault.maxRedeem(alice), aliceAmount, "alice maxRedeem");
        assertEq(vault.maxRedeem(bob), bobAmount, "bob maxRedeem");

        // Bob claims, alice's counter stays
        vm.prank(bob);
        vault.claimRequestById(bobRequestId);

        assertEq(vault.maxRedeem(alice), aliceAmount, "alice unchanged after bob claims");
        assertEq(vault.maxRedeem(bob), 0, "bob zero after claim");
    }

    /*//////////////////////////////////////////////////////////////
                    PURE REVERT / ZERO FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice withdraw() always reverts.
    function test_Withdraw_Reverts() external {
        vm.expectRevert(IOllaVault.OllaVault__NotSupported.selector);
        vault.withdraw(1, alice, alice);
    }

    /// @notice maxWithdraw() always returns zero.
    function test_MaxWithdraw_ReturnsZero() external view {
        assertEq(vault.maxWithdraw(alice), 0, "maxWithdraw always zero");
    }

    /// @notice previewWithdraw() always reverts.
    function test_PreviewWithdraw_Reverts() external {
        vm.expectRevert(IOllaVault.OllaVault__NotSupported.selector);
        vault.previewWithdraw(1);
    }

    /// @notice previewRedeem() always reverts.
    function test_PreviewRedeem_Reverts() external {
        vm.expectRevert(IOllaVault.OllaVault__NotSupported.selector);
        vault.previewRedeem(1);
    }

    /*//////////////////////////////////////////////////////////////
                     SUPPORTS INTERFACE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice supportsInterface returns true for ERC7540Redeem.
    function test_SupportsInterface_ERC7540Redeem() external view {
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId), "supports ERC7540Redeem");
    }

    /// @notice supportsInterface returns true for ERC7540Operator.
    function test_SupportsInterface_ERC7540Operator() external view {
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId), "supports ERC7540Operator");
    }

    /// @notice supportsInterface returns true for ERC7575.
    function test_SupportsInterface_ERC7575() external view {
        assertTrue(vault.supportsInterface(type(IERC7575).interfaceId), "supports ERC7575");
    }

    /// @notice supportsInterface returns false for a random interface.
    function test_SupportsInterface_RejectRandom() external view {
        assertFalse(vault.supportsInterface(bytes4(0xdeadbeef)), "rejects random interface");
    }

    /*//////////////////////////////////////////////////////////////
              PENDING REDEEM REQUEST / CLAIMABLE REDEEM REQUEST
    //////////////////////////////////////////////////////////////*/

    /// @notice pendingRedeemRequest returns pending shares.
    function test_PendingRedeemRequest_ReturnsPendingShares() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        uint256 requestId = _performRequestRedeem(alice, shares);

        assertEq(vault.pendingRedeemRequest(requestId, alice), shares, "pending shares");
    }

    /// @notice pendingRedeemRequest returns zero after finalization.
    function test_PendingRedeemRequest_ReturnsZeroWhenFinalized() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        uint256 requestId = _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        assertEq(vault.pendingRedeemRequest(requestId, alice), 0, "zero after finalized");
    }

    /// @notice pendingRedeemRequest returns zero for wrong controller.
    function test_PendingRedeemRequest_ReturnsZeroWrongController() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        uint256 requestId = _performRequestRedeem(alice, shares);

        assertEq(vault.pendingRedeemRequest(requestId, bob), 0, "zero for wrong controller");
    }

    /// @notice claimableRedeemRequest returns claimable shares after finalization.
    function test_ClaimableRedeemRequest_ReturnsClaimableShares() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        uint256 requestId = _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        assertEq(vault.claimableRedeemRequest(requestId, alice), shares, "claimable shares");
    }

    /// @notice claimableRedeemRequest returns zero when still pending.
    function test_ClaimableRedeemRequest_ReturnsZeroWhenPending() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        uint256 requestId = _performRequestRedeem(alice, shares);

        assertEq(vault.claimableRedeemRequest(requestId, alice), 0, "zero when pending");
    }

    /// @notice claimableRedeemRequest returns zero after claim.
    function test_ClaimableRedeemRequest_ReturnsZeroWhenClaimed() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);
        uint256 requestId = _performRequestRedeem(alice, shares);

        _finalizeAll(depositAmount);

        vm.prank(alice);
        vault.claimRequestById(requestId);

        assertEq(vault.claimableRedeemRequest(requestId, alice), 0, "zero after claimed");
    }
}
