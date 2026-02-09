// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";

/// @title ClaimAfterRebalanceTest
/// @notice Validates that finalized-but-unclaimed withdrawal tokens are NOT re-staked
///         by a subsequent rebalance, thanks to the _finalizedUnclaimedAssets mechanism.
///
///         The _finalizedUnclaimedAssets counter reserves tokens in OllaCore so that
///         _syncBufferedWithBalance() and _stakeSurplus() do not treat them as available
///         buffer to re-stake.
contract ClaimAfterRebalanceTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    WithdrawalQueue internal queue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(coreProxy));

        governance = makeAddr("governance");
        operator = makeAddr("operator");
        alice = makeAddr("alice");

        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        WithdrawalQueue queueImpl = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImpl), abi.encodeCall(WithdrawalQueue.initialize, (address(vault), governance))
        );
        queue = WithdrawalQueue(address(queueProxy));

        // Configure staking manager to actually move tokens on stake/unstake
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));
        stakingManager.setUnstakedToken(asset);

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0, // protocolFeeBP
            0, // treasuryFeeSplitBP
            governance,
            address(queue),
            rewardsVault,
            address(safetyModule)
        );

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        asset.mint(user, assets);
        vm.prank(user);
        asset.approve(address(vault), assets);
        vm.prank(user);
        shares = vault.deposit(assets, user);
    }

    function _rebalance() internal {
        vm.prank(operator);
        vault.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
             CLAIM SUCCEEDS AFTER INTERVENING REBALANCES
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that a finalized withdrawal claim succeeds even after a subsequent
    ///         rebalance, because _finalizedUnclaimedAssets prevents the earmarked tokens
    ///         from being reconciled into bufferedAssets and re-staked.
    ///
    ///         Timeline:
    ///         1. Alice deposits 100 ETH
    ///         2. Rebalance #1: stakes 100 ETH to staking manager (tokens leave OllaCore)
    ///         3. Alice requests full withdrawal
    ///         4. Rebalance #2: unstaked funds pulled back, withdrawal finalized.
    ///            Tokens are in OllaCore, reserved via _finalizedUnclaimedAssets.
    ///         5. Rebalance #3: _syncBufferedWithBalance() correctly excludes reserved tokens.
    ///            _stakeSurplus() does not re-stake them.
    ///         6. Alice claims successfully.
    function test_ClaimSucceeds_AfterSubsequentRebalance() external {
        uint256 depositAmount = 100 * DECIMALS;

        // Step 1: Alice deposits
        _deposit(alice, depositAmount);

        assertEq(asset.balanceOf(address(vault)), depositAmount, "vault holds deposit");
        assertEq(vault.accountingState().bufferedAssets, depositAmount, "buffered matches deposit");

        // Step 2: First rebalance stakes all assets (targetBufferedAssets is 0)
        _rebalance();

        assertEq(asset.balanceOf(address(vault)), 0, "vault empty after staking");
        assertEq(vault.accountingState().bufferedAssets, 0, "buffer zeroed after staking");
        assertEq(vault.accountingState().stakedPrincipal, depositAmount, "staked principal = deposit");

        // Step 3: Alice requests full withdrawal
        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(aliceShares, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        uint256 assetsExpected = request.assetsExpected;
        assertFalse(request.finalized, "request not yet finalized");
        assertEq(queue.totalPendingAssets(), assetsExpected, "queue tracks pending amount");

        // Step 4: Second rebalance - simulate unstaked funds becoming available.
        // In the real StakingManager + MockAztecRollup, _pullUnstakedFunds would pull from
        // the rollup. With MockAccountingStakingManager, we set the unstaked amount
        // and fund the mock so it can transfer back.
        asset.mint(address(stakingManager), depositAmount);
        stakingManager.setUnstakedAmount(depositAmount);

        _rebalance();

        // Verify the withdrawal was finalized
        request = queue.getRequest(requestId);
        assertTrue(request.finalized, "request should be finalized after rebalance #2");
        assertEq(queue.totalPendingAssets(), 0, "no more pending assets");

        // OllaCore holds the tokens, reserved for Alice's claim
        uint256 vaultBalanceAfterFinalize = asset.balanceOf(address(vault));
        assertGe(vaultBalanceAfterFinalize, assetsExpected, "vault holds tokens for claim");

        // Step 5: Another rebalance runs -- tokens must NOT be re-staked
        _rebalance();

        // Tokens are still in OllaCore (protected by _finalizedUnclaimedAssets)
        uint256 vaultBalanceAfterRebalance = asset.balanceOf(address(vault));
        assertGe(vaultBalanceAfterRebalance, assetsExpected, "vault still holds claim tokens after rebalance #3");

        // Step 6: Alice claims successfully
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        assertEq(claimed, assetsExpected, "claimed amount matches expected");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, assetsExpected, "alice received expected assets");
    }

    /// @notice Same scenario but the claim happens immediately after finalization (no intervening
    ///         rebalance). This is the simplest happy path.
    function test_ClaimSucceeds_WhenNoRebalanceBetweenFinalizeAndClaim() external {
        uint256 depositAmount = 100 * DECIMALS;

        // Step 1: Alice deposits
        _deposit(alice, depositAmount);

        // Step 2: First rebalance stakes all assets
        _rebalance();

        // Step 3: Alice requests full withdrawal
        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(aliceShares, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        uint256 assetsExpected = request.assetsExpected;

        // Step 4: Second rebalance - simulate unstaked funds and finalize
        asset.mint(address(stakingManager), depositAmount);
        stakingManager.setUnstakedAmount(depositAmount);
        _rebalance();

        // Verify finalized
        request = queue.getRequest(requestId);
        assertTrue(request.finalized, "request finalized");

        // Step 5: Alice claims immediately (no intervening rebalance)
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        assertEq(claimed, assetsExpected, "claimed amount matches expected");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, assetsExpected, "alice received expected assets");
    }

    /// @notice Verifies claim succeeds with a non-zero targetBufferedAssets and rewards,
    ///         even after multiple intervening rebalances. Closest to the local dev loop.
    function test_ClaimSucceeds_WithRewardsBuffer_AfterMultipleRebalances() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 targetBuffer = 10 * DECIMALS;

        // Set a target buffer so rewards aren't immediately staked away
        vm.prank(governance);
        vault.setTargetBufferedAssets(targetBuffer);

        // Step 1: Alice deposits
        _deposit(alice, depositAmount);

        // Step 2: First rebalance stakes surplus (deposit - targetBuffer)
        _rebalance();
        uint256 staked = depositAmount - targetBuffer;
        assertEq(asset.balanceOf(address(vault)), targetBuffer, "vault retains target buffer");
        assertEq(vault.accountingState().bufferedAssets, targetBuffer, "buffer = target");
        assertEq(vault.accountingState().stakedPrincipal, staked, "staked = deposit - target");

        // Step 3: Simulate rewards harvest
        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);
        _rebalance();
        stakingManager.setHarvestedRewards(0);

        // Step 4: Alice requests full withdrawal
        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(aliceShares, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        uint256 assetsExpected = request.assetsExpected;

        // Step 5: Rebalance that pulls unstaked funds and finalizes
        asset.mint(address(stakingManager), staked + rewardAmount);
        stakingManager.setUnstakedAmount(staked + rewardAmount);
        _rebalance();

        // Verify finalization
        request = queue.getRequest(requestId);
        assertTrue(request.finalized, "request should be finalized");
        assertEq(queue.totalPendingAssets(), 0, "no pending assets");

        // OllaCore holds enough for the claim
        uint256 vaultBalance = asset.balanceOf(address(vault));
        assertGe(vaultBalance, assetsExpected, "vault should have enough for claim");

        // Step 6: Multiple rebalances run before Alice claims
        _rebalance();
        _rebalance();

        // Tokens are still reserved
        uint256 vaultBalanceAfter = asset.balanceOf(address(vault));
        assertGe(vaultBalanceAfter, assetsExpected, "vault still holds claim tokens after rebalances");

        // Step 7: Alice claims successfully
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 aliceBalanceAfter = asset.balanceOf(alice);
        assertEq(claimed, assetsExpected, "claimed amount matches expected");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, assetsExpected, "alice received expected assets");
    }
}
