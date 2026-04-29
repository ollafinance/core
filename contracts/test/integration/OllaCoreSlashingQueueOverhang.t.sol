// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreSlashingQueueOverhangTest is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;
    address internal alice;
    address internal bob;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setUnstakedToken(asset);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));
        vault.initialize(asset, stAztec, address(core), governance);

        vm.startPrank(governance);
        core.setVault(address(vault));
        core.unpause();
        vault.unpause();
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1);
    }

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-USER SLASHING FINALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice After slashing, both Alice and Bob's requests finalize at the reduced rate.
    function test_SlashingAdjustsAndFinalizesQueue() external {
        uint256 aliceDeposit = 60 * DECIMALS;
        uint256 bobDeposit = 40 * DECIMALS;
        _deposit(alice, aliceDeposit);
        _deposit(bob, bobDeposit);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        stakingManager.setStakeReturnAmount(aliceDeposit + bobDeposit);
        stakingManager.setAllowStakeReturnExceeds(true);
        stakingManager.setTotalStaked(aliceDeposit + bobDeposit);

        vm.prank(operator);
        core.rebalance();
        assertEq(vault.bufferedAssets(), 0, "all assets should be staked");

        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceRequestId = vault.requestRedeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobRequestId = vault.requestRedeem(10 * DECIMALS, bob, bob);

        IOllaVault.WithdrawalRequest memory aliceRequest = vault.getWithdrawalRequest(aliceRequestId);
        IOllaVault.WithdrawalRequest memory bobRequest = vault.getWithdrawalRequest(bobRequestId);
        assertEq(aliceRequest.assetsExpected, aliceDeposit, "alice request locks pre-slash value");
        assertEq(bobRequest.assetsExpected, 10 * DECIMALS, "bob request uses same stale rate");
        assertEq(vault.pendingWithdrawalAssets(), 70 * DECIMALS, "queue tracks both requests");

        // Realized slash after requests are already locked in the queue.
        // setSlashingDelta mirrors real StakingManager: it reduces totalStakedAmount by 50e18
        // (from 100e18 to 50e18) and records the cumulative loss.
        stakingManager.setSlashingDelta(50 * DECIMALS);
        core.updateAccounting();

        // All surviving assets become liquid.
        stakingManager.setUnstakedAmount(50 * DECIMALS);
        stakingManager.setTotalStaked(0);
        stakingManager.setStakeReturnAmount(0);
        asset.mint(address(stakingManager), 50 * DECIMALS);

        uint256 firstCycleTimestamp = block.timestamp + 1 hours + 1;
        vm.warp(firstCycleTimestamp);
        vm.prank(operator);
        core.rebalance();

        // With the fix, both requests finalize at the post-slash rate.
        aliceRequest = vault.getWithdrawalRequest(aliceRequestId);
        bobRequest = vault.getWithdrawalRequest(bobRequestId);
        assertTrue(aliceRequest.finalized, "alice request finalizes after adjustment");
        assertTrue(bobRequest.finalized, "bob request finalizes after adjustment");

        // Payouts are proportional: each share gets (50 total / 100 original shares) = 0.5 per share.
        // Alice: 60 shares * 0.5 ~= 30; Bob: 10 shares * 0.5 ~= 5.
        // Virtual offset (1e3) introduces sub-wei rounding in the withdrawal rate.
        assertApproxEqAbs(aliceRequest.assetsExpected, 30 * DECIMALS, 1e3, "alice payout adjusted to post-slash rate");
        assertApproxEqAbs(bobRequest.assetsExpected, 5 * DECIMALS, 1e3, "bob payout adjusted to post-slash rate");
        assertEq(vault.pendingWithdrawalAssets(), 0, "queue fully drained");
    }

    /*//////////////////////////////////////////////////////////////
                   SINGLE-USER SLASHING FINALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice A single depositor's request finalizes at the reduced rate after a 1-token slash.
    function test_SingleDepositorFinalizesAfterSlashing() external {
        uint256 depositAmount = 100 * DECIMALS;
        _deposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setAllowStakeReturnExceeds(true);
        stakingManager.setTotalStaked(depositAmount);

        vm.prank(operator);
        core.rebalance();
        assertEq(vault.bufferedAssets(), 0, "all assets should be staked");

        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(aliceShares, alice, alice);

        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);
        assertEq(request.assetsExpected, depositAmount, "request locks full pre-slash value");
        assertEq(vault.pendingWithdrawalAssets(), depositAmount, "queue tracks locked liability");

        // 1-token slash after request.
        // totalStaked stays at original pre-slash principal -- slashingDelta tracks the loss.
        stakingManager.setSlashingDelta(1 * DECIMALS);
        core.updateAccounting();

        // Unstake all remaining assets.
        stakingManager.setUnstakedAmount(99 * DECIMALS);
        stakingManager.setTotalStaked(0);
        stakingManager.setStakeReturnAmount(0);
        asset.mint(address(stakingManager), 99 * DECIMALS);

        uint256 firstCycleTimestamp = block.timestamp + 1 hours + 1;
        vm.warp(firstCycleTimestamp);
        vm.prank(operator);
        core.rebalance();

        // Request finalizes at the post-slash rate.
        request = vault.getWithdrawalRequest(requestId);
        assertTrue(request.finalized, "request finalizes after adjustment");
        // 100 shares * (99/100 rate) = 99e18 payout
        assertEq(request.assetsExpected, 99 * DECIMALS, "payout adjusted to 99 (post-slash)");
        assertEq(vault.pendingWithdrawalAssets(), 0, "queue fully drained");
    }

    /*//////////////////////////////////////////////////////////////
                          HAPPY PATH (NO SLASH)
    //////////////////////////////////////////////////////////////*/

    /// @notice Without slashing, no adjustment occurs and payout equals original assetsExpected.
    function test_NoAdjustmentWithoutSlashing() external {
        uint256 depositAmount = 50 * DECIMALS;
        _deposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setAllowStakeReturnExceeds(true);
        stakingManager.setTotalStaked(depositAmount);

        vm.prank(operator);
        core.rebalance();

        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(aliceShares, alice, alice);

        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);
        assertEq(request.assetsExpected, depositAmount, "request at deposit rate");

        // Unstake all assets (no slashing).
        stakingManager.setUnstakedAmount(depositAmount);
        stakingManager.setTotalStaked(0);
        stakingManager.setStakeReturnAmount(0);
        asset.mint(address(stakingManager), depositAmount);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(operator);
        core.rebalance();

        request = vault.getWithdrawalRequest(requestId);
        assertTrue(request.finalized, "request finalizes normally");
        assertEq(request.assetsExpected, depositAmount, "no adjustment when no slashing");
        assertEq(vault.pendingWithdrawalAssets(), 0, "queue fully drained");
    }

    /*//////////////////////////////////////////////////////////////
                    EXCHANGE RATE DURING QUEUED SLASH
    //////////////////////////////////////////////////////////////*/

    /// @notice Pending withdrawal liabilities should be slash-adjusted for live exchange-rate pricing.
    function test_ExchangeRateUsesSlashAdjustedPendingWithdrawals() external {
        uint256 aliceDeposit = 50 * DECIMALS;
        uint256 bobDeposit = 50 * DECIMALS;
        _deposit(alice, aliceDeposit);
        _deposit(bob, bobDeposit);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        uint256 totalDeposits = aliceDeposit + bobDeposit;
        stakingManager.setStakeReturnAmount(totalDeposits);
        stakingManager.setAllowStakeReturnExceeds(true);
        stakingManager.setTotalStaked(totalDeposits);

        vm.prank(operator);
        core.rebalance();
        assertEq(vault.bufferedAssets(), 0, "all assets should be staked");

        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(aliceShares, alice, alice);

        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);
        assertEq(request.assetsExpected, aliceDeposit, "request locks pre-slash value");
        assertEq(vault.pendingWithdrawalAssets(), aliceDeposit, "queue tracks pre-slash liability");
        assertEq(vault.pendingWithdrawalShares(), aliceShares, "queue tracks burned shares");

        // A slash occurs after Alice's request but before her withdrawal is finalized. The live
        // exchange rate for Bob's remaining shares should match the gross withdrawal rate so both
        // queued and non-queued shares absorb the slash pro-rata during this interim window.
        stakingManager.setSlashingDelta(20 * DECIMALS);
        core.updateAccounting();

        uint256 withdrawalRateAfterSlash = core.withdrawalRate();
        uint256 exchangeRateAfterSlash = core.exchangeRate();
        assertEq(exchangeRateAfterSlash, withdrawalRateAfterSlash, "exchange rate should not double-discount pending");
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM AFTER ADJUSTMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice User claims the adjusted (lower) amount after slashing.
    function test_ClaimReceivesAdjustedAmount() external {
        uint256 depositAmount = 100 * DECIMALS;
        _deposit(alice, depositAmount);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        stakingManager.setStakeReturnAmount(depositAmount);
        stakingManager.setAllowStakeReturnExceeds(true);
        stakingManager.setTotalStaked(depositAmount);

        vm.prank(operator);
        core.rebalance();

        uint256 aliceShares = stAztec.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(aliceShares, alice, alice);

        // 10% slash.
        // totalStaked stays at original pre-slash principal -- slashingDelta tracks the loss.
        stakingManager.setSlashingDelta(10 * DECIMALS);
        core.updateAccounting();

        // Unstake and make liquid.
        stakingManager.setUnstakedAmount(90 * DECIMALS);
        stakingManager.setTotalStaked(0);
        stakingManager.setStakeReturnAmount(0);
        asset.mint(address(stakingManager), 90 * DECIMALS);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(operator);
        core.rebalance();

        // Verify request finalized at adjusted amount.
        IOllaVault.WithdrawalRequest memory request = vault.getWithdrawalRequest(requestId);
        assertTrue(request.finalized, "request finalized");
        assertEq(request.assetsExpected, 90 * DECIMALS, "adjusted to 90% of original");

        // Claim and verify user receives the adjusted amount.
        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);
        uint256 aliceBalanceAfter = asset.balanceOf(alice);

        assertEq(claimed, 90 * DECIMALS, "claim returns adjusted amount");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, 90 * DECIMALS, "user receives adjusted amount");
    }
}
