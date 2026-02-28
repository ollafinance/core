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
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract RebalanceInProgressIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                              TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
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
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(core));
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        safetyModule =
            new SafetyModule(admin, guardian, address(core), address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days);
        operator = makeAddr("operator");
        user = makeAddr("user");

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));
        stakingManager.setUnstakedToken(asset);

        withdrawalQueue.initialize(address(vault), governance, 180_000);

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsVault, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        vm.startPrank(admin);
        safetyModule.setMinRateDropBps(safetyModule.MAX_RATE_DROP_BPS());
        vm.stopPrank();

        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        vm.stopPrank();

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);
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
            (bool success,) = address(core).call{ gas: gasOptions[i] }(abi.encodeCall(core.rebalance, ()));
            if (!success) {
                continue;
            }
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
                selectedGas = gasOptions[i];
                break;
            }
        }

        vm.revertToState(snapshotId);
        assertGt(selectedGas, 0, "should find gas stipend");
    }

    /*//////////////////////////////////////////////////////////////
                    USER ACTIONS DURING REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice User deposit/requestRedeem/claim all work during rebalance in progress.
    function test_UserActions_AllowedDuringRebalance() external {
        _performDeposit(user, 12 * DECIMALS);

        uint256 shares = core.convertToShares(3 * DECIMALS);
        (uint256 requestId,) = _requestRedeem(user, shares, user);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        core.rebalance{ gas: gasLimit }();

        // Rebalance is in progress (not Done)
        assertNotEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance in progress"
        );

        // Deposit succeeds during rebalance in progress
        asset.mint(user, 2 * DECIMALS);
        vm.prank(user);
        asset.approve(address(vault), 2 * DECIMALS);
        vm.prank(user);
        vault.deposit(2 * DECIMALS, user, 0);

        // RequestRedeem succeeds during rebalance in progress
        vm.prank(user);
        vault.requestRedeem(1 * DECIMALS, user);

        // Claims revert if not yet finalized (rebalance stopped before FinalizeWithdrawals),
        // but this is a queue error, not a rebalance-pause error.
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__NotFinalized.selector, requestId));
        vm.prank(user);
        vault.claimRequestById(requestId);

        // Complete the rebalance to finalize the request
        stakingManager.setActivatedAttesterCount(0);
        stakingManager.setTotalStaked(9 * DECIMALS);
        vm.prank(operator);
        core.rebalance();

        assertEq(uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance completed");

        // Now claim the finalized request
        vm.prank(user);
        vault.claimRequestById(requestId);
    }

    /// @notice Admin setters are blocked during rebalance with OllaCore__RebalanceInProgress.
    function test_AdminActions_BlockedDuringRebalance() external {
        _performDeposit(user, 12 * DECIMALS);

        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        core.rebalance{ gas: gasLimit }();

        // Rebalance is in progress
        assertNotEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "rebalance in progress"
        );

        // Admin setters should revert with OllaCore__RebalanceInProgress
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        vm.prank(governance);
        core.setTargetBufferedAssets(1);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalanceInProgress.selector));
        vm.prank(governance);
        core.setProtocolFeeBP(1);

        // Complete the rebalance
        stakingManager.setActivatedAttesterCount(0);
        stakingManager.setTotalStaked(9 * DECIMALS);
        vm.prank(operator);
        core.rebalance();

        // Admin setters succeed after rebalance completes
        vm.prank(governance);
        core.setTargetBufferedAssets(1 * DECIMALS);
        assertEq(core.targetBufferedAssets(), 1 * DECIMALS, "setTargetBufferedAssets works after rebalance");
    }

    /// @notice Claims of previously-finalized requests work during rebalance in progress.
    function test_ClaimFinalized_DuringRebalance() external {
        _performDeposit(user, 12 * DECIMALS);

        uint256 shares = core.convertToShares(3 * DECIMALS);
        (uint256 requestId, uint256 assetsExpected) = _requestRedeem(user, shares, user);

        // Complete first rebalance to finalize the withdrawal request
        stakingManager.setActivatedAttesterCount(0);
        stakingManager.setTotalStaked(9 * DECIMALS);
        vm.prank(operator);
        core.rebalance();

        assertEq(
            uint256(core.rebalanceProgress().step), uint256(IOllaCore.RebalanceStep.Done), "first rebalance completed"
        );

        // Create a new request to make a second rebalance have work to do
        uint256 newShares = core.convertToShares(1 * DECIMALS);
        vm.prank(user);
        vault.requestRedeem(newShares, user);

        // Start a second rebalance and stop mid-way
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 gasLimit = _findGasForPullUnstakedStop();
        vm.prank(operator);
        core.rebalance{ gas: gasLimit }();

        assertNotEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "second rebalance in progress"
        );

        // Claim the previously-finalized request while rebalance is in progress
        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 claimed = vault.claimRequestById(requestId);
        assertEq(claimed, assetsExpected, "claimed matches expected assets");
        assertEq(asset.balanceOf(user) - userBalanceBefore, assetsExpected, "user receives claimed assets");

        // Deposits succeed during rebalance in progress
        asset.mint(user, 1 * DECIMALS);
        vm.prank(user);
        asset.approve(address(vault), 1 * DECIMALS);
        vm.prank(user);
        vault.deposit(1 * DECIMALS, user, 0);
    }
}
