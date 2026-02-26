// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MaliciousAztec } from "src/staking/mocks/MaliciousAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";

contract OllaCoreInstantRedemptionTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event InstantRedemption(
        address indexed owner,
        address indexed recipient,
        uint256 shares,
        uint256 grossAssets,
        uint256 fee,
        uint256 netAssets,
        uint256 exchangeRate
    );

    event InstantRedemptionFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant BP_DIVISOR = 10_000;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @dev Storage slot for `_accountingState.bufferedAssets` (from `forge inspect OllaCore storage-layout`).
    uint256 internal constant BUFFERED_ASSETS_SLOT = 6;
    /// @dev Storage slot for `_accountingState.stakedPrincipal` (slot 7).
    uint256 internal constant STAKED_PRINCIPAL_SLOT = 7;
    /// @dev Storage slot for `_finalizedUnclaimedAssets` (from `forge inspect OllaCore storage-layout`).
    uint256 internal constant FINALIZED_UNCLAIMED_SLOT = 30;
    /// @dev Storage slot for `_rebalanceIdleBuffer`.
    uint256 internal constant REBALANCE_IDLE_BUFFER_SLOT = 31;
    /// @dev Storage slot for `_rebalanceProgress` (struct at slot 23).
    uint256 internal constant REBALANCE_PROGRESS_SLOT = 23;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    address internal permitOwner;
    uint256 internal permitOwnerKey;
    uint256 internal permitAttackerKey;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        permitOwnerKey = 0xA11CE;
        permitOwner = vm.addr(permitOwnerKey);
        permitAttackerKey = 0xB0B;

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

    function _setInstantRedemptionFee(uint256 feeBP) internal {
        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(feeBP);
    }

    function _setFinalizedUnclaimedAssets(uint256 amount) internal {
        vm.store(address(vault), bytes32(FINALIZED_UNCLAIMED_SLOT), bytes32(amount));
    }

    function _setBufferedAssets(uint256 amount) internal {
        vm.store(address(vault), bytes32(BUFFERED_ASSETS_SLOT), bytes32(amount));
    }

    function _setStakedPrincipal(uint256 amount) internal {
        vm.store(address(vault), bytes32(STAKED_PRINCIPAL_SLOT), bytes32(amount));
    }

    function _setRebalanceIdleBuffer(uint256 amount) internal {
        vm.store(address(vault), bytes32(REBALANCE_IDLE_BUFFER_SLOT), bytes32(amount));
    }

    function _getRebalanceIdleBuffer() internal view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(REBALANCE_IDLE_BUFFER_SLOT)));
    }

    function _setRebalanceInProgress() internal {
        // Set rebalance step to PullUnstaked (non-Done) to simulate in-progress rebalance
        vm.store(
            address(vault), bytes32(REBALANCE_PROGRESS_SLOT), bytes32(uint256(IOllaCore.RebalanceStep.PullUnstaked))
        );
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
                    1. HAPPY PATH — redeem succeeds
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_TransfersCorrectNetAssetsToRecipient() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 50 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 fee = grossAssets * 500 / BP_DIVISOR;
        uint256 expectedNet = grossAssets - fee;

        vm.prank(alice);
        uint256 netAssets = vault.redeem(sharesToRedeem, bob, 0);

        assertEq(netAssets, expectedNet, "return value matches expected net assets");
        assertEq(asset.balanceOf(bob), expectedNet, "bob receives net assets");
    }

    /*//////////////////////////////////////////////////////////////
                       2. SHARE BURNING
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_BurnsSharesFromCaller() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 40 * DECIMALS;
        uint256 supplyBefore = stAztec.totalSupply();

        vm.prank(alice);
        vault.redeem(sharesToRedeem, bob, 0);

        assertEq(stAztec.balanceOf(alice), shares - sharesToRedeem, "alice shares decreased");
        assertEq(stAztec.totalSupply(), supplyBefore - sharesToRedeem, "total supply decreased");
    }

    /*//////////////////////////////////////////////////////////////
                     3. BUFFER DECREASE
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_DecreasesBufferedAssetsByGrossAssets() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        IOllaCore.AccountingState memory stateBefore = vault.accountingState();
        uint256 sharesToRedeem = 30 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);

        vm.prank(alice);
        vault.redeem(sharesToRedeem, bob, 0);

        IOllaCore.AccountingState memory stateAfter = vault.accountingState();
        assertEq(stateAfter.bufferedAssets, stateBefore.bufferedAssets - grossAssets, "buffer decreased by grossAssets");
    }

    /*//////////////////////////////////////////////////////////////
                  4. FEE TRANSFER TO TREASURY
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_TransfersFeeToGovernance() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 govBalanceBefore = asset.balanceOf(governance);
        uint256 sharesToRedeem = 50 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 expectedFee = grossAssets * 500 / BP_DIVISOR;

        vm.prank(alice);
        vault.redeem(sharesToRedeem, bob, 0);

        uint256 govBalanceAfter = asset.balanceOf(governance);
        assertEq(govBalanceAfter - govBalanceBefore, expectedFee, "governance receives fee");
    }

    /*//////////////////////////////////////////////////////////////
                      5. EVENT EMISSION
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_EmitsInstantRedemptionEvent() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 50 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 fee = grossAssets * 500 / BP_DIVISOR;
        uint256 netAssets = grossAssets - fee;

        vm.expectEmit(true, true, true, true, address(vault));
        emit InstantRedemption(alice, bob, sharesToRedeem, grossAssets, fee, netAssets, rate);

        vm.prank(alice);
        vault.redeem(sharesToRedeem, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
              6. REVERT: INSUFFICIENT LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_InsufficientLiquidity() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Reduce available liquidity via finalized encumbrance.
        // Deposit 100 → balance = 100, buffered = 100, alice has 100 shares.
        // Mint 30 to vault, set finalized = 80, set buffered = 50, set stakedPrincipal = 50.
        // totalAssets = buffered(50) + staked(50) = 100, totalSupply = 100 → rate = 1:1.
        // Reconcile: available = balance(130) - finalized(80) = 50 >= buffered(50) ✓ (no delta).
        // available = bufferedAssets = 50.
        // At 1:1 rate, 60 shares → grossAssets = 60 > available (50) → revert.
        asset.mint(address(vault), 30 * DECIMALS);
        _setFinalizedUnclaimedAssets(80 * DECIMALS);
        _setBufferedAssets(50 * DECIMALS);
        _setStakedPrincipal(50 * DECIMALS);

        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__InsufficientLiquidity.selector, 60 * DECIMALS, 50 * DECIMALS)
        );
        vm.prank(alice);
        vault.redeem(60 * DECIMALS, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
                  7. REVERT: ZERO RECIPIENT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_ZeroRecipient() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "recipient"));
        vm.prank(alice);
        vault.redeem(10 * DECIMALS, address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    8. REVERT: ZERO SHARES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_ZeroShares() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.expectRevert(IOllaCore.OllaCore__InvalidAmount.selector);
        vm.prank(alice);
        vault.redeem(0, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     9. REVERT: PAUSED
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_Paused() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        vault.redeem(10 * DECIMALS, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
            10. REVERT: SAFETY MODULE PAUSED
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_SafetyModulePaused() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        safetyModule.pause();

        vm.expectRevert(IOllaCore.OllaCore__SafetyModulePaused.selector);
        vm.prank(alice);
        vault.redeem(10 * DECIMALS, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
        12. SAFETY MODULE checkWithdrawalMinimum
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_RespectsSafetyModuleWithdrawalMinimum() external {
        // MockSafetyModule.checkWithdrawalMinimum is a no-op so this is a smoke test
        // that the call is reached without reverting
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(alice);
        uint256 net = vault.redeem(10 * DECIMALS, bob, 0);
        assertGt(net, 0, "redemption succeeded through safety module check");
    }

    /*//////////////////////////////////////////////////////////////
      13. _syncBufferedWithBalance IS CALLED
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_SyncsBufferBeforeComputingAvailability() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Directly send additional AZTEC to vault (untracked transfer)
        uint256 bonus = 50 * DECIMALS;
        asset.mint(address(vault), bonus);

        // Before redeem, bufferedAssets is 100 but actual balance is 150
        IOllaCore.AccountingState memory stateBefore = vault.accountingState();
        assertEq(stateBefore.bufferedAssets, depositAmount, "buffer before sync");

        // Redeem should sync first, making buffer = 150, then deduct grossAssets
        uint256 sharesToRedeem = 10 * DECIMALS;
        vm.prank(alice);
        vault.redeem(sharesToRedeem, bob, 0);

        IOllaCore.AccountingState memory stateAfter = vault.accountingState();
        // After sync (150) minus grossAssets
        uint256 rate = vault.exchangeRate();
        // Note: rate may have changed slightly due to totalAssets increase from sync
        // But the key point is buffer should be > depositAmount - grossAssets
        assertGt(stateAfter.bufferedAssets, depositAmount - sharesToRedeem, "buffer reflects sync before deduction");
    }

    /*//////////////////////////////////////////////////////////////
                     14. FLOW COUNTERS
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_UpdatesCumulativeWithdrawals() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        IOllaCore.FlowCounters memory flowsBefore = vault.flowCounters();

        uint256 sharesToRedeem = 30 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);

        vm.prank(alice);
        vault.redeem(sharesToRedeem, bob, 0);

        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
        assertEq(
            flowsAfter.cumulativeWithdrawals,
            flowsBefore.cumulativeWithdrawals + grossAssets,
            "cumulative withdrawals increased by grossAssets"
        );
    }

    /*//////////////////////////////////////////////////////////////
             15. REBALANCE IDLE BUFFER RESET
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_ResetsRebalanceIdleBuffer() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Set _rebalanceIdleBuffer to nonzero
        _setRebalanceIdleBuffer(depositAmount);
        assertEq(_getRebalanceIdleBuffer(), depositAmount, "idle buffer set");

        vm.prank(alice);
        vault.redeem(10 * DECIMALS, bob, 0);

        assertEq(_getRebalanceIdleBuffer(), 0, "idle buffer reset after redeem");
    }

    /*//////////////////////////////////////////////////////////////
                  16. PERMIT: HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_RedeemWithPermit_WorksEndToEnd() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(permitOwner, depositAmount);

        uint256 sharesToRedeem = 30 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), sharesToRedeem, deadline
        );

        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 fee = grossAssets * 500 / BP_DIVISOR;
        uint256 expectedNet = grossAssets - fee;

        vm.prank(permitOwner);
        uint256 netAssets = vault.redeemWithPermit(sharesToRedeem, bob, 0, deadline, v, r, s);

        assertEq(netAssets, expectedNet, "net assets match");
        assertEq(asset.balanceOf(bob), expectedNet, "bob receives net assets");
        assertEq(IERC20Permit(address(stAztec)).nonces(permitOwner), 1, "nonce incremented");
    }

    /*//////////////////////////////////////////////////////////////
              17. PERMIT: INVALID SIGNATURE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RedeemWithPermit_InvalidSignature() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(permitOwner, depositAmount);

        uint256 sharesToRedeem = 30 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            IERC20Permit(address(stAztec)), permitOwner, permitAttackerKey, address(vault), sharesToRedeem, deadline
        );

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(permitAttackerKey), permitOwner)
        );
        vm.prank(permitOwner);
        vault.redeemWithPermit(sharesToRedeem, bob, 0, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
     18. availableForInstantRedemption — CORRECT COMPUTATION
    //////////////////////////////////////////////////////////////*/

    function test_AvailableForInstantRedemption_ReturnsCorrectValue() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // After deposit: buffered = 100 (reconciled). available = bufferedAssets = 100.
        assertEq(vault.availableForInstantRedemption(), depositAmount, "full buffer available");

        // Mint 30 extra tokens to vault and set finalized = 30.
        // View returns bufferedAssets which is still 100 (no sync triggered by view).
        asset.mint(address(vault), 30 * DECIMALS);
        _setFinalizedUnclaimedAssets(30 * DECIMALS);
        assertEq(vault.availableForInstantRedemption(), 100 * DECIMALS, "buffered unchanged before sync");
    }

    /*//////////////////////////////////////////////////////////////
     19. availableForInstantRedemption — FULLY ENCUMBERED
    //////////////////////////////////////////////////////////////*/

    function test_AvailableForInstantRedemption_ReturnsZeroWhenFullyEncumbered() external {
        // available = bufferedAssets.
        // A fresh vault (no deposits) has bufferedAssets = 0.
        assertEq(vault.availableForInstantRedemption(), 0, "zero when no deposits");
    }

    /*//////////////////////////////////////////////////////////////
        20. setInstantRedemptionFeeBP — ADMIN SETTER
    //////////////////////////////////////////////////////////////*/

    function test_SetInstantRedemptionFeeBP_UpdatesAndEmits() external {
        vm.expectEmit(true, true, true, true, address(vault));
        emit InstantRedemptionFeeUpdated(500, 1000);

        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(1000);

        assertEq(vault.instantRedemptionFeeBP(), 1000, "fee updated");
    }

    /*//////////////////////////////////////////////////////////////
      21. setInstantRedemptionFeeBP — NON-ADMIN REVERT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetInstantRedemptionFeeBP_NonAdmin() external {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vault.setInstantRedemptionFeeBP(1000);
    }

    /*//////////////////////////////////////////////////////////////
      22. setInstantRedemptionFeeBP — EXCEEDS MAX
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetInstantRedemptionFeeBP_ExceedsMax() external {
        uint256 aboveMax = vault.MAX_INSTANT_REDEMPTION_FEE_BP() + 1;
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, aboveMax));
        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(aboveMax);
    }

    /*//////////////////////////////////////////////////////////////
      23. setInstantRedemptionFeeBP — PAUSED / REBALANCE-PAUSED
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetInstantRedemptionFeeBP_Paused() external {
        vm.prank(governance);
        vault.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(1000);
    }

    function test_RevertWhen_SetInstantRedemptionFeeBP_RebalanceInProgress() external {
        // Directly set rebalance step to non-Done via storage
        _setRebalanceInProgress();

        vm.expectRevert(IOllaCore.OllaCore__RebalanceInProgress.selector);
        vm.prank(governance);
        vault.setInstantRedemptionFeeBP(1000);
    }

    /*//////////////////////////////////////////////////////////////
               24. ZERO FEE — NO DEDUCTION
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_ZeroFee_FullAssetsToRecipient() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        _setInstantRedemptionFee(0);

        uint256 sharesToRedeem = 50 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);

        uint256 govBalanceBefore = asset.balanceOf(governance);

        vm.prank(alice);
        uint256 netAssets = vault.redeem(sharesToRedeem, bob, 0);

        assertEq(netAssets, grossAssets, "netAssets == grossAssets when fee is 0");
        assertEq(asset.balanceOf(bob), grossAssets, "bob receives full gross assets");
        assertEq(asset.balanceOf(governance), govBalanceBefore, "governance receives nothing");
    }

    /*//////////////////////////////////////////////////////////////
          25. MULTIPLE SEQUENTIAL REDEMPTIONS
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_MultipleSequentialRedemptions_TracksBufferCorrectly() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        IOllaCore.AccountingState memory stateStart = vault.accountingState();
        IOllaCore.FlowCounters memory flowsStart = vault.flowCounters();

        uint256 rate = vault.exchangeRate();
        uint256 totalGross;

        // Redeem 20
        uint256 gross1 = uint256(20 * DECIMALS).mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        vm.prank(alice);
        vault.redeem(20 * DECIMALS, bob, 0);
        totalGross += gross1;

        // Redeem 30
        rate = vault.exchangeRate();
        uint256 gross2 = uint256(30 * DECIMALS).mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        vm.prank(alice);
        vault.redeem(30 * DECIMALS, bob, 0);
        totalGross += gross2;

        // Redeem 10
        rate = vault.exchangeRate();
        uint256 gross3 = uint256(10 * DECIMALS).mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        vm.prank(alice);
        vault.redeem(10 * DECIMALS, bob, 0);
        totalGross += gross3;

        IOllaCore.AccountingState memory stateEnd = vault.accountingState();
        IOllaCore.FlowCounters memory flowsEnd = vault.flowCounters();

        assertEq(
            stateEnd.bufferedAssets, stateStart.bufferedAssets - totalGross, "buffer decreased by sum of grossAssets"
        );
        assertEq(
            flowsEnd.cumulativeWithdrawals,
            flowsStart.cumulativeWithdrawals + totalGross,
            "cumulative withdrawals match"
        );
    }

    /*//////////////////////////////////////////////////////////////
        26. NO INTERFERENCE WITH ASYNC FLOW
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_DoesNotInterfereWithAsyncFlow() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Instant redeem 20
        vm.prank(alice);
        vault.redeem(20 * DECIMALS, bob, 0);

        // Async requestRedeem 30
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(30 * DECIMALS, alice);

        assertGt(requestId, 0, "async request created");
        assertEq(vault.requestOwner(requestId), alice, "request owner is alice");

        // Claim should work
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        assertGt(claimed, 0, "claim succeeded");
    }

    /*//////////////////////////////////////////////////////////////
       27. REDEMPTION FOLLOWED BY REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_FollowedByRebalance_CorrectAccounting() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(alice);
        vault.redeem(30 * DECIMALS, bob, 0);

        // Run rebalance — should not revert
        vm.prank(governance);
        (uint256 rewardsDelta, uint256 finalizedAmount, uint256 stakedAmount, uint256 resultingBuffer) =
            vault.rebalance();

        // Accounting should be consistent
        IOllaCore.AccountingState memory stateAfter = vault.accountingState();
        assertEq(stateAfter.bufferedAssets, resultingBuffer, "accounting consistent after rebalance");
    }

    /*//////////////////////////////////////////////////////////////
          28. EDGE CASE: EXACTLY AVAILABLE
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_ExactlyAvailableSucceeds() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // fee=5%, so grossAssets = shares at 1:1. We need grossAssets <= available (100).
        // At 1:1 rate, grossAssets = shares. So redeem exactly 100 shares => grossAssets = 100 = available.
        vm.prank(alice);
        uint256 netAssets = vault.redeem(100 * DECIMALS, bob, 0);

        assertGt(netAssets, 0, "redemption succeeded");
        assertEq(vault.availableForInstantRedemption(), 0, "buffer fully drained");
    }

    /*//////////////////////////////////////////////////////////////
        29. EDGE CASE: AVAILABLE + 1 WEI REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_AvailablePlusOneWei() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // available = bufferedAssets = 100 after deposit.
        // Try to redeem 101 shares at 1:1 rate → grossAssets = 101 > available (100).
        // Liquidity check fires before burn, so alice not having 101 shares doesn't matter.
        uint256 redeemAmount = depositAmount + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__InsufficientLiquidity.selector, redeemAmount, depositAmount)
        );
        vm.prank(alice);
        vault.redeem(redeemAmount, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
         30. DEFAULT FEE INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_InstantRedemptionFeeBP_DefaultsTo500() external view {
        assertEq(vault.instantRedemptionFeeBP(), 500, "default fee is 5%");
    }

    /*//////////////////////////////////////////////////////////////
                     31. FUZZ TEST
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Redeem_FeeNetSplit(uint96 depositAmount, uint96 redeemShares, uint16 feeBP) external {
        depositAmount = uint96(bound(depositAmount, 2, type(uint96).max));
        feeBP = uint16(bound(feeBP, 0, 2_000));

        uint256 shares = _performDeposit(alice, depositAmount);

        _setInstantRedemptionFee(feeBP);

        // Bound redeemShares to [1, shares] and also ensure grossAssets <= available
        uint256 available = vault.availableForInstantRedemption();
        uint256 rate = vault.exchangeRate();
        // maxSharesByLiquidity: available * EXCHANGE_RATE_SCALE / rate (floor)
        uint256 maxSharesByLiquidity = available.mulDiv(DECIMALS, rate, Math.Rounding.Floor);
        uint256 maxRedeem = shares < maxSharesByLiquidity ? shares : maxSharesByLiquidity;
        if (maxRedeem == 0) return; // skip if no room
        redeemShares = uint96(bound(redeemShares, 1, maxRedeem));

        uint256 grossAssets = uint256(redeemShares).mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 expectedFee = grossAssets * feeBP / BP_DIVISOR;
        uint256 expectedNet = grossAssets - expectedFee;

        uint256 govBefore = asset.balanceOf(governance);

        vm.prank(alice);
        uint256 netAssets = vault.redeem(redeemShares, bob, 0);

        assertEq(netAssets, expectedNet, "net assets match");
        assertEq(netAssets + expectedFee, grossAssets, "net + fee == gross");
        assertEq(asset.balanceOf(bob), expectedNet, "bob receives net");
        assertEq(asset.balanceOf(governance) - govBefore, expectedFee, "governance receives fee");
    }

    /*//////////////////////////////////////////////////////////////
              32. REENTRANCY PROTECTION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_ReenteredFromTransferHook() external {
        // Deploy a fresh vault using MaliciousAztec as the underlying asset so we can
        // trigger a reentrancy attempt from the ERC-20 transfer hook inside _redeem.
        MaliciousAztec malAsset = new MaliciousAztec();

        OllaCoreHarness malCoreImpl = new OllaCoreHarness();
        ERC1967Proxy malProxy = new ERC1967Proxy(address(malCoreImpl), "");
        OllaCoreHarness malVault = OllaCoreHarness(address(malProxy));

        MockAccountingStakingManager malStakingManager = new MockAccountingStakingManager();
        StAztec malStAztec = new StAztec(address(malVault));
        MockRewardsVault malRewardsVault = new MockRewardsVault(IERC20(address(malAsset)), address(malVault));
        MockSafetyModule malSafetyModule = new MockSafetyModule(address(malCoreImpl));
        MockWithdrawalQueue malWithdrawalQueue = new MockWithdrawalQueue();

        malStakingManager.setRewardsToken(IERC20(address(malAsset)));
        malStakingManager.setRewardsVault(address(malRewardsVault));

        malVault.initialize(
            IERC20(address(malAsset)),
            malStAztec,
            malStakingManager,
            0,
            5_000,
            governance,
            address(malWithdrawalQueue),
            malRewardsVault,
            address(malSafetyModule)
        );

        vm.prank(governance);
        malVault.unpause();

        // Deposit so alice has shares and the vault has balance
        uint256 depositAmount = 100 * DECIMALS;
        malAsset.mint(alice, depositAmount);
        vm.prank(alice);
        IERC20(address(malAsset)).approve(address(malVault), depositAmount);
        vm.prank(alice);
        malVault.deposit(depositAmount, alice, 0);

        // Configure the malicious token to re-enter redeem() during the safeTransfer call
        uint256 sharesToRedeem = 10 * DECIMALS;
        malAsset.configureTransferReentry(
            address(malVault), abi.encodeCall(malVault.redeem, (sharesToRedeem, bob, 0)), true
        );

        // The outer redeem triggers safeTransfer → transfer hook → re-enters redeem → nonReentrant reverts.
        // The revert from the inner call propagates through Address.functionCall, reverting the outer call.
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        malVault.redeem(sharesToRedeem, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
          33. SELF-REDEMPTION (owner == recipient)
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_SelfRedemption_OwnerEqualsRecipient() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 shares = _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 50 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 fee = grossAssets * 500 / BP_DIVISOR;
        uint256 expectedNet = grossAssets - fee;

        uint256 aliceAssetBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 netAssets = vault.redeem(sharesToRedeem, alice, 0);

        assertEq(netAssets, expectedNet, "return value matches expected net assets");
        assertEq(asset.balanceOf(alice) - aliceAssetBefore, expectedNet, "alice asset balance increases by netAssets");
        assertEq(stAztec.balanceOf(alice), shares - sharesToRedeem, "alice shares burned correctly");
    }

    /*//////////////////////////////////////////////////////////////
       34. RECIPIENT IS GOVERNANCE (fee + net same address)
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_RecipientIsGovernance_ReceivesGrossAssets() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 50 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);

        uint256 govBalanceBefore = asset.balanceOf(governance);

        vm.prank(alice);
        vault.redeem(sharesToRedeem, governance, 0);

        uint256 govBalanceAfter = asset.balanceOf(governance);
        assertEq(govBalanceAfter - govBalanceBefore, grossAssets, "governance receives gross assets (net + fee)");
    }

    /*//////////////////////////////////////////////////////////////
        35. NON-1:1 EXCHANGE RATE (rewards accrue)
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_NonOneToOneExchangeRate_CorrectFeeNetSplit() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Simulate rewards: mint extra AZTEC directly to vault (untracked)
        uint256 rewards = 50 * DECIMALS;
        asset.mint(address(vault), rewards);

        // After sync (triggered by redeem), bufferedAssets = 150e18
        // totalSupply = 100e18 shares, so rate = 150e18 * 1e18 / 100e18 = 1.5e18
        uint256 sharesToRedeem = 50 * DECIMALS;

        // Perform redeem — this triggers _syncBufferedWithBalance() first
        vm.prank(alice);
        uint256 netAssets = vault.redeem(sharesToRedeem, bob, 0);

        // With virtual offset: grossAssets = shares * (totalAssets + 1) / (supply + 1)
        // After sync: totalAssets = 150e18, supply = 100e18 (pre-redeem values used in contract)
        uint256 syncedTotalAssets = depositAmount + rewards; // 150e18
        uint256 preRedeemSupply = depositAmount; // 100e18 (supply before the redeem burned shares)
        uint256 expectedGross = sharesToRedeem.mulDiv(syncedTotalAssets + 1, preRedeemSupply + 1, Math.Rounding.Floor);
        uint256 expectedFee = expectedGross * 500 / BP_DIVISOR;
        uint256 expectedNet = expectedGross - expectedFee;

        assertGt(expectedGross, sharesToRedeem, "grossAssets > shares at rate > 1e18");
        assertEq(netAssets, expectedNet, "net assets match expected at higher rate");
        assertEq(asset.balanceOf(bob), expectedNet, "bob receives correct net assets");
        assertEq(asset.balanceOf(governance), expectedFee, "governance receives correct fee");
    }

    /*//////////////////////////////////////////////////////////////
      36. EXPIRED PERMIT DEADLINE REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RedeemWithPermit_ExpiredDeadline() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(permitOwner, depositAmount);

        uint256 sharesToRedeem = 30 * DECIMALS;
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), sharesToRedeem, deadline
        );

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        vm.prank(permitOwner);
        vault.redeemWithPermit(sharesToRedeem, bob, 0, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
      37. totalAssets DECREASES AFTER REDEMPTION
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_TotalAssetsDecreasesbyGrossAssets() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 sharesToRedeem = 40 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);

        vm.prank(alice);
        vault.redeem(sharesToRedeem, bob, 0);

        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore - grossAssets, "totalAssets decreased by grossAssets");
    }

    /*//////////////////////////////////////////////////////////////
      39. REDEEM MATCHES convertToAssets (NO DOUBLE-MULDIV ROUNDING)
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures _redeem computes grossAssets identically to the public
    ///         convertToAssets view, proving there is no double-mulDiv rounding
    ///         discrepancy between the two paths.  Uses a non-trivial exchange
    ///         rate that would surface a 1-wei divergence under the old
    ///         two-step _exchangeRate() → mulDiv(rate, scale) approach.
    function test_Redeem_GrossAssetsMatchesConvertToAssets() external {
        // Deposit an amount that produces a non-trivial rate when rewards arrive.
        // 3 is chosen because totalAssets / supply won't divide evenly.
        uint256 depositAmount = 3;
        _performDeposit(alice, depositAmount);

        // Simulate rewards that create an awkward rate: totalAssets = 1e18 + 1, supply = 3
        uint256 rewards = 1 ether - 3 + 1; // after sync: totalAssets = 1e18 + 1 - 3 + 3 = 1e18+1
        asset.mint(address(vault), rewards);

        // Snapshot convertToAssets BEFORE redeem (sync hasn't happened yet,
        // so we trigger a sync-aware read by calling redeem).
        // Instead, we compute what convertToAssets WILL return after sync:
        // totalAssets after sync = balance - 0 (no finalized) = depositAmount + rewards = 1e18+1
        // supply = 3
        uint256 sharesToRedeem = 2;

        // Read preview from convertToAssets — this is a view that doesn't sync,
        // but after sync totalAssets = actual balance = depositAmount + rewards.
        // We can't call convertToAssets post-sync without actually syncing, so we
        // compute it manually with the single-step formula.
        uint256 expectedTotalAssets = depositAmount + rewards;
        uint256 supply = stAztec.totalSupply();
        uint256 expectedGross = sharesToRedeem.mulDiv(expectedTotalAssets + 1, supply + 1, Math.Rounding.Floor);

        // Perform the redeem — triggers _syncBufferedWithBalance() then _convertToAssets()
        _setInstantRedemptionFee(0); // zero fee so netAssets == grossAssets
        vm.prank(alice);
        uint256 netAssets = vault.redeem(sharesToRedeem, bob, 0);

        // The critical assertion: redeem output must EXACTLY match the single-step
        // mulDiv computation. The old double-mulDiv would be off by 1 wei here.
        assertEq(netAssets, expectedGross, "redeem grossAssets matches single-step convertToAssets formula");

        // Also verify convertToAssets (post-redeem state) is consistent for remaining shares
        uint256 remainingShares = stAztec.balanceOf(alice);
        if (remainingShares > 0) {
            uint256 viewAssets = vault.convertToAssets(remainingShares);
            uint256 postTotal = vault.totalAssets();
            uint256 postSupply = stAztec.totalSupply();
            uint256 expectedRemaining = remainingShares.mulDiv(postTotal + 1, postSupply + 1, Math.Rounding.Floor);
            assertEq(viewAssets, expectedRemaining, "convertToAssets consistent post-redeem");
        }
    }

    /*//////////////////////////////////////////////////////////////
                   FUZZ: FEE BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Redeem_ZeroFeeBoundary(uint96 depositAmount, uint96 redeemSeed) external {
        depositAmount = uint96(bound(depositAmount, 2e18, type(uint96).max));
        _performDeposit(alice, depositAmount);

        _setInstantRedemptionFee(0);

        uint256 shares = stAztec.balanceOf(alice);
        uint256 maxRedeem = vault.availableForInstantRedemption();
        uint256 rate = vault.exchangeRate();
        uint256 maxSharesByLiquidity = maxRedeem.mulDiv(DECIMALS, rate, Math.Rounding.Floor);
        uint256 upperBound = shares < maxSharesByLiquidity ? shares : maxSharesByLiquidity;
        vm.assume(upperBound > 0);
        uint256 sharesToRedeem = bound(uint256(redeemSeed), 1, upperBound);

        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 govBefore = asset.balanceOf(governance);

        vm.prank(alice);
        uint256 netAssets = vault.redeem(sharesToRedeem, bob, 0);

        assertEq(netAssets, grossAssets, "0% fee: netAssets == grossAssets");
        assertEq(asset.balanceOf(governance) - govBefore, 0, "0% fee: governance gets 0");
    }

    function testFuzz_Redeem_MaxFeeBoundary(uint96 depositAmount, uint96 redeemSeed) external {
        depositAmount = uint96(bound(depositAmount, 2e18, type(uint96).max));
        _performDeposit(alice, depositAmount);

        _setInstantRedemptionFee(2_000); // 20% fee (MAX_INSTANT_REDEMPTION_FEE_BP)

        uint256 shares = stAztec.balanceOf(alice);
        uint256 maxRedeem = vault.availableForInstantRedemption();
        uint256 rate = vault.exchangeRate();
        uint256 maxSharesByLiquidity = maxRedeem.mulDiv(DECIMALS, rate, Math.Rounding.Floor);
        uint256 upperBound = shares < maxSharesByLiquidity ? shares : maxSharesByLiquidity;
        vm.assume(upperBound > 0);
        uint256 sharesToRedeem = bound(uint256(redeemSeed), 1, upperBound);

        uint256 grossAssets = sharesToRedeem.mulDiv(rate, DECIMALS, Math.Rounding.Floor);
        uint256 expectedFee = grossAssets * 2_000 / BP_DIVISOR;
        uint256 expectedNet = grossAssets - expectedFee;
        uint256 govBefore = asset.balanceOf(governance);

        vm.prank(alice);
        uint256 netAssets = vault.redeem(sharesToRedeem, bob, 0);

        assertEq(netAssets, expectedNet, "20% fee: netAssets == grossAssets - fee");
        assertEq(asset.balanceOf(governance) - govBefore, expectedFee, "20% fee: governance gets fee");
    }
}
