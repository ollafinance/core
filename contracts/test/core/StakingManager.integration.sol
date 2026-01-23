// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { StakingManager } from "src/core/StakingManager.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsVault } from "src/mocks/MockRewardsVault.sol";
import { G1Point, G2Point } from "src/libraries/BN254Lib.sol";

contract StakingManagerIntegrationTest is Test {
    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;

    event RewardsHarvested(uint256 indexed amount);
    event UnstakedFundsClaimed(uint256 indexed amount);

    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    MockRewardsVault internal rewardsVault;
    StakingManager internal stakingManager;

    address internal core;
    address internal providerAdmin;
    address internal defaultAdmin;
    address internal treasury;

    function setUp() external {
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");
        treasury = makeAddr("treasury");

        aztec = new MockAztec(address(this));
        rollup = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));
        rewardsVault = new MockRewardsVault(IERC20(address(aztec)), core, treasury);

        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        stakingManager = StakingManager(address(proxy));
        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsVault),
            core,
            providerAdmin,
            providerAdmin,
            defaultAdmin
        );
    }

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory keys) {
        keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = IStakingManager.KeyStore({
                // forge-lint: disable-next-line(unsafe-typecast)
                attester: address(uint160(i + 1)),
                publicKeyG1: G1Point({ x: i, y: i + 1 }),
                publicKeyG2: G2Point({ x0: i, x1: i + 1, y0: i + 2, y1: i + 3 }),
                proofOfPossession: G1Point({ x: i + 10, y: i + 11 })
            });
        }
        return keys;
    }

    function _stake(uint256 attesterCount) internal returns (IStakingManager.KeyStore[] memory keys) {
        keys = _createMockKeys(attesterCount);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        uint256 amount = ACTIVATION_THRESHOLD * attesterCount;
        aztec.mint(core, amount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), amount);
        stakingManager.stake(amount);
        vm.stopPrank();

        return keys;
    }

    function test_Stake_RoutesAssetsToRollup_AndActivatesAttesters() external {
        uint256 stakeAmount = ACTIVATION_THRESHOLD * 2;
        IStakingManager.KeyStore[] memory keys = _createMockKeys(2);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, stakeAmount);
        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();

        assertEq(stakingManager.getQueueLength(), 0);
        assertEq(stakingManager.getActivatedAttesterCount(), 2);
        assertEq(aztec.balanceOf(address(rollup)), stakeAmount);
        assertEq(aztec.balanceOf(core), coreBalanceBefore - stakeAmount);
    }

    function test_Unstake_ThenGetUnstakedFunds_ReturnsAssetsToCore() external {
        _stake(1);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        assertEq(stakingManager.getActivatedAttesterCount(), 0);
        assertEq(stakingManager.getPendingUnstakeCount(), 1);

        uint256 coreBalanceBefore = aztec.balanceOf(core);

        vm.recordLogs();
        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 expectedSelector = keccak256("UnstakedFundsClaimed(uint256)");
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(stakingManager)) continue;
            if (entries[i].topics[0] != expectedSelector) continue;
            uint256 amount = uint256(entries[i].topics[1]);
            assertEq(amount, ACTIVATION_THRESHOLD);
            found = true;
            break;
        }
        assertTrue(found, "UnstakedFundsClaimed event not found");

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_GetUnstakedFunds_SkipsNotReadyExits() external {
        IStakingManager.KeyStore[] memory keys = _stake(2);

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD * 2);

        rollup.setExitReady(keys[0].attester, block.timestamp + 1 days);

        uint256 coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 1);
        assertTrue(stakingManager.isUnstakePending(keys[0].attester));

        vm.warp(block.timestamp + 2 days);

        coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + ACTIVATION_THRESHOLD);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
        assertFalse(stakingManager.isUnstakePending(keys[0].attester));
    }

    function test_CleanActivatedAttesters_MovesExternalExitsToPending_ThenClaims() external {
        uint256 total = 3;
        uint256 exited = 2;
        IStakingManager.KeyStore[] memory keys = _stake(total);

        for (uint256 i; i < exited; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }

        vm.prank(core);
        stakingManager.cleanActivatedAttesters();

        assertEq(stakingManager.getActivatedAttesterCount(), total - exited);
        assertEq(stakingManager.getPendingUnstakeCount(), exited);

        uint256 coreBalanceBefore = aztec.balanceOf(core);
        vm.prank(core);
        uint256 claimed = stakingManager.getUnstakedFunds();

        assertEq(claimed, ACTIVATION_THRESHOLD * exited);
        assertEq(aztec.balanceOf(core), coreBalanceBefore + claimed);
        assertEq(stakingManager.getPendingUnstakeCount(), 0);
    }

    function test_HarvestRewards_ClaimsToStakingManager_AndCallsRewardsVaultHook() external {
        _stake(1);

        uint256 rewards = 10 ether;
        aztec.mint(address(rollup), rewards);
        rollup.setRewards(address(rewardsVault), rewards);

        uint256 totalReceivedBefore = rewardsVault.totalReceived();

        vm.expectEmit(true, true, true, true, address(stakingManager));
        emit RewardsHarvested(rewards);

        vm.prank(core);
        uint256 harvested = stakingManager.harvestRewards();

        assertEq(harvested, rewards);
        assertEq(rewardsVault.totalReceived(), totalReceivedBefore + rewards);
        assertEq(rollup.getSequencerRewards(address(rewardsVault)), 0);
        assertEq(aztec.balanceOf(address(stakingManager)), rewards);
    }

    function test_RevertWhen_Stake_UnauthorizedCaller() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), stakingManager.CORE_ROLE()
            )
        );
        stakingManager.stake(ACTIVATION_THRESHOLD);
    }
}
