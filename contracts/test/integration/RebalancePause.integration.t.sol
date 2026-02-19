// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

contract RebalancePauseIntegrationTest is Test {
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
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    SafetyModule internal safetyModule;
    address internal governance;
    address internal admin;
    address internal guardian;
    address internal operator;
    address internal user;

    /*//////////////////////////////////////////////////////////////
                                   SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        safetyModule = new SafetyModule(admin, guardian, address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days);
        operator = makeAddr("operator");
        user = makeAddr("user");

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));
        stakingManager.setUnstakedToken(asset);

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
        withdrawalQueue.initialize(address(vault), governance);

        vm.startPrank(admin);
        safetyModule.setMinRateDropBps(safetyModule.MAX_RATE_DROP_BPS());
        vm.stopPrank();

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 amount) internal returns (uint256 shares) {
        asset.mint(owner, amount);
        vm.prank(owner);
        asset.approve(address(vault), amount);
        vm.prank(owner);
        shares = vault.deposit(amount, owner, 0);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares, address recipient)
        internal
        returns (uint256 requestId, uint256 assetsExpected)
    {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, recipient);
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        assetsExpected = request.assetsExpected;
        return (requestId, assetsExpected);
    }

    function _findGasForPullUnstakedStop() internal returns (uint256 selectedGas) {
        uint256 snapshotId = vm.snapshotState();
        uint256[6] memory gasOptions = [uint256(120_000), 140_000, 160_000, 180_000, 200_000, 220_000];

        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            vm.prank(operator);
            (bool success,) = address(vault).call{ gas: gasOptions[i] }(abi.encodeCall(vault.rebalance, ()));
            if (!success) {
                continue;
            }
            IOllaCore.RebalanceProgress memory progress = vault.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        vm.revertToState(snapshotId);
        assertGt(selectedGas, 0, "should find gas stipend");
    }

    /*//////////////////////////////////////////////////////////////
                             REBALANCE PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_RebalancePause_GatesUserActions_ThenResumes() external {
        _performDeposit(user, 12 * DECIMALS);

        uint256 shares = vault.convertToShares(3 * DECIMALS);
        (uint256 requestId,) = _requestRedeem(user, shares, user);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        assertTrue(vault.isRebalancePaused(), "pause active");

        asset.mint(user, 2 * DECIMALS);
        vm.prank(user);
        asset.approve(address(vault), 2 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(user);
        vault.deposit(2 * DECIMALS, user, 0);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(user);
        vault.requestRedeem(1 * DECIMALS, user);

        // Claims are allowed during rebalance pause, but will revert from the queue
        // if the request is not yet finalized (rebalance stopped before FinalizeWithdrawals).
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__NotFinalized.selector, requestId));
        vm.prank(user);
        vault.claimRequestById(requestId);

        // Complete the rebalance to finalize the request
        stakingManager.setActivatedAttesterCount(0);
        stakingManager.setTotalStaked(9 * DECIMALS);
        vm.prank(operator);
        vault.rebalance();

        assertFalse(vault.isRebalancePaused(), "pause cleared");

        asset.mint(user, 1 * DECIMALS);
        vm.prank(user);
        asset.approve(address(vault), 1 * DECIMALS);
        vm.prank(user);
        vault.deposit(1 * DECIMALS, user, 0);

        vm.prank(user);
        vault.requestRedeem(1 * DECIMALS, user);

        // Now claim the finalized request (rebalance is not paused here)
        vm.prank(user);
        vault.claimRequestById(requestId);
    }

    function test_RebalancePause_AllowsClaimOfFinalizedRequest() external {
        _performDeposit(user, 12 * DECIMALS);

        uint256 shares = vault.convertToShares(3 * DECIMALS);
        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(user, shares, user);

        // Complete first rebalance to finalize the withdrawal request
        stakingManager.setActivatedAttesterCount(0);
        stakingManager.setTotalStaked(9 * DECIMALS);
        vm.prank(operator);
        vault.rebalance();

        assertFalse(vault.isRebalancePaused(), "first rebalance completed");

        // Create a new request to make a second rebalance have work to do
        uint256 newShares = vault.convertToShares(1 * DECIMALS);
        vm.prank(user);
        vault.requestRedeem(newShares, user);

        // Start a second rebalance and pause mid-way
        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        vault.rebalance{ gas: gasLimit }();

        assertTrue(vault.isRebalancePaused(), "second rebalance pause active");

        // Claim the previously-finalized request while rebalance is paused
        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 claimed = vault.claimRequestById(requestId);
        assertEq(claimed, assetsExpected, "claimed matches expected assets");
        assertEq(asset.balanceOf(user) - userBalanceBefore, assetsExpected, "user receives claimed assets");

        // Deposits are still blocked
        asset.mint(user, 1 * DECIMALS);
        vm.prank(user);
        asset.approve(address(vault), 1 * DECIMALS);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(user);
        vault.deposit(1 * DECIMALS, user, 0);
    }
}
