// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";

contract OllaCoreWithdrawalQueueHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedApplyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsVaultBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) external {
        _applyAccountingUpdates(
            newStakedPrincipal, newRewardsVaultBalance, newClaimableRewards, newRewardsDelta, newSlashingDelta
        );
    }
}

contract OllaCoreWithdrawalQueueTest is Test {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        address indexed recipient,
        uint256 shares,
        uint256 assetsExpected,
        uint256 exchangeRate
    );

    event WithdrawalClaimed(uint256 requestId, address recipient, uint256 assets);

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreWithdrawalQueueHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    WithdrawalQueue internal queue;
    address internal governance;
    MockRewardsVault internal rewardsVault;
    SafetyModule internal safetyModule;
    address internal admin;
    address internal guardian;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreWithdrawalQueueHarness coreImplementation = new OllaCoreWithdrawalQueueHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreWithdrawalQueueHarness(address(coreProxy));

        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        rewardsVault = new MockRewardsVault(asset, address(coreImplementation));
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        safetyModule = new SafetyModule(admin, guardian, address(vault), 1_000_000 ether, 500, 6_000, 1 days);

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        queue = WithdrawalQueue(address(queueProxy));

        vault.initialize(
            asset, stAztec, stakingManager, 0, 0, governance, address(queue), rewardsVault, address(safetyModule)
        );
        queue.initialize(address(vault), governance);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /*//////////////////////////////////////////////////////////////
                        REQUEST REDEEM FLOW
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_BurnsShares() external {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 ether, alice);

        assertEq(requestId, 1, "request id starts at 1");
        assertEq(stAztec.balanceOf(alice), shares - 4 ether, "shares burned on request");
    }

    function test_RequestRedeem_LocksAssetsExpectedAtRequestRate() external {
        _deposit(alice, 12 ether);
        uint256 rate = vault.exchangeRate();
        uint256 shares = 5 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected locked at request rate");
        assertEq(request.rate, rate, "rate locked at request time");

        vault.exposedApplyAccountingUpdates(0, 3 ether, 0, 0, 0);
        uint256 updatedRate = vault.exchangeRate();
        assertGt(updatedRate, rate, "exchange rate should increase after rewards");
        request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected unchanged after rate update");
        assertEq(request.rate, rate, "rate remains locked after update");
    }

    function test_RequestRedeem_EventMatchesQueueStorage() external {
        _deposit(alice, 20 ether);
        uint256 rate = vault.exchangeRate();
        uint256 shares = 7 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.expectEmit(true, true, true, true, address(vault));
        emit WithdrawalRequested(1, alice, bob, shares, expectedAssets, rate);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.recipient, bob, "queue stores recipient");
        assertEq(request.shares, shares, "queue stores share amount");
        assertEq(request.assetsExpected, expectedAssets, "queue stores assets expected");
        assertEq(request.rate, rate, "queue stores request rate");
    }

    function test_RequestRedeem_UpdatesQueueTotals() external {
        _deposit(alice, 25 ether);
        _deposit(bob, 15 ether);

        (, uint256 assetsExpectedAlice) = _requestRedeem(alice, 8 ether, alice);
        assertEq(queue.totalPendingAssets(), assetsExpectedAlice, "pending assets tracks first request");
        assertEq(queue.nextRequestId(), 2, "next request id increments after first request");
        assertEq(queue.nextPendingId(), 1, "next pending id stays at first request");

        (, uint256 assetsExpectedBob) = _requestRedeem(bob, 5 ether, bob);
        assertEq(
            queue.totalPendingAssets(), assetsExpectedAlice + assetsExpectedBob, "pending assets accumulates requests"
        );
        assertEq(queue.nextRequestId(), 3, "next request id increments after second request");
        assertEq(queue.nextPendingId(), 1, "next pending id remains earliest request");
    }

    function test_RequestRedeem_AssetsExpectedMatchesRate() external {
        _deposit(alice, 18 ether);
        vault.exposedApplyAccountingUpdates(0, 6 ether, 0, 0, 0);

        uint256 rate = vault.exchangeRate();
        uint256 shares = 9 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        (uint256 requestId,) = _requestRedeem(alice, shares, alice);
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);

        assertEq(request.assetsExpected, expectedAssets, "assetsExpected should match rate at request time");
        assertEq(request.rate, rate, "request rate should match current rate");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_AllowsMultipleRequests() external {
        _deposit(alice, 15 ether);

        vm.prank(alice);
        uint256 firstRequestId = vault.requestRedeem(5 ether, alice);
        vm.prank(alice);
        uint256 secondRequestId = vault.requestRedeem(2 ether, bob);

        assertEq(firstRequestId, 1, "first request id");
        assertEq(secondRequestId, 2, "second request id");
        assertEq(queue.nextRequestId(), 3, "next request id increments");
    }

    function test_RequestRedeem_AllowsWhenPaused() external {
        _deposit(alice, 10 ether);

        vm.prank(governance);
        vault.pause();

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 ether, alice);

        assertEq(requestId, 1, "request should succeed while paused");
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM FLOW
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ClaimNotFinalized() external {
        _deposit(alice, 10 ether);

        (uint256 requestId,) = _requestRedeem(alice, 5 ether, alice);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__NotFinalized.selector, requestId));
        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    function test_RevertWhen_DoubleClaim() external {
        _deposit(alice, 10 ether);

        (uint256 requestId,) = _requestRedeem(alice, 5 ether, alice);
        vault.rebalance();

        vm.prank(alice);
        vault.claimRequestById(requestId);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__AlreadyClaimed.selector, requestId));
        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    function test_ClaimTransfersExpectedAssets() external {
        _deposit(alice, 12 ether);

        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(alice, 6 ether, bob);
        vault.rebalance();

        uint256 receiverBalanceBefore = asset.balanceOf(bob);

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 receiverBalanceAfter = asset.balanceOf(bob);
        assertEq(claimed, assetsExpected, "claimed assets should equal assetsExpected");
        assertEq(receiverBalanceAfter - receiverBalanceBefore, assetsExpected, "receiver gets expected assets");
    }

    function test_ClaimRequestById_ByOwnerClaimsFullRequest() external {
        _deposit(alice, 14 ether);

        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(alice, 7 ether, bob);
        vault.rebalance();

        uint256 receiverBalanceBefore = asset.balanceOf(bob);

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 receiverBalanceAfter = asset.balanceOf(bob);
        assertEq(requestId, 1, "request id should be first");
        assertEq(claimed, assetsExpected, "redeem should claim full assetsExpected");
        assertEq(receiverBalanceAfter - receiverBalanceBefore, assetsExpected, "redeem claims full assetsExpected");
    }

    function test_ClaimAllowedWhenPaused() external {
        _deposit(alice, 10 ether);

        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(alice, 5 ether, alice);
        vault.rebalance();

        vm.prank(governance);
        vault.pause();

        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        assertEq(claimed, assetsExpected, "claim should succeed while paused");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares, address recipient)
        internal
        returns (uint256 requestId, uint256 assetsExpected)
    {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, recipient);
        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assetsExpected = request.assetsExpected;
        return (requestId, assetsExpected);
    }
}
