// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { StakingManagerBaseTest } from "./StakingManagerBase.t.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

/// @notice Harness that exposes the internal `_setActive` for direct testing.
contract StakingManagerHarness is StakingManager {
    function exposed_setActive(address attester, uint256 stakedAmount) external {
        _setActive(attester, stakedAmount);
    }
}

contract StakingManagerDuplicateAttesterTest is StakingManagerBaseTest {
    StakingManagerHarness internal harness;

    function setUp() public override {
        super.setUp();

        // Deploy a harness behind a proxy for direct _setActive testing
        StakingManagerHarness harnessImpl = new StakingManagerHarness();
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), "");
        harness = StakingManagerHarness(address(harnessProxy));
        harness.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsAccumulator),
            core,
            address(stakingProviderRegistry),
            defaultAdmin
        );
    }

    /*//////////////////////////////////////////////////////////////
                  _setActive DEFENSE-IN-DEPTH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetActive_DuplicateAttester() external {
        address attester = address(uint160(42));

        // First activation succeeds
        harness.exposed_setActive(attester, 100 ether);

        // Second activation of the same attester reverts
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterAlreadyActive.selector, attester)
        );
        harness.exposed_setActive(attester, 100 ether);
    }

    function test_SetActive_AccountingCorrectOnSingleActivation() external {
        address attester = address(uint160(42));

        harness.exposed_setActive(attester, 100 ether);

        IStakingManager.StakingState memory state = harness.getStakingState();
        assertEq(state.stakedAmount, 100 ether, "stakedAmount should be 100 ether");
        assertEq(harness.getActivatedAttesterCount(), 1, "should have 1 active attester");
    }

    /*//////////////////////////////////////////////////////////////
              FULL FLOW: DUPLICATE VIA REGISTRY BLOCKED
    //////////////////////////////////////////////////////////////*/

    function test_Stake_DuplicateKeyInRegistry_RevertsAtRegistry() external {
        // Add a key
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        // Stake it (consumes the key from the queue)
        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // Re-add same key to registry succeeds (registry cleared on dequeue)
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        // But staking it again should revert at _setActive (defense-in-depth)
        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__AttesterAlreadyActive.selector, keys[0].attester)
        );
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
          FULL LIFECYCLE: RESTAKE AFTER EXIT SUCCEEDS
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_RestakeAfterExitSucceeds() external {
        // 1. Add key and stake
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);

        // 2. Unstake
        stakingManager.unstake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        // 3. Refresh to finalize exit
        address[] memory attesters = new address[](1);
        attesters[0] = keys[0].attester;
        stakingManager.refreshAttesterState(attesters);

        // 4. Claim unstaked funds
        vm.prank(core);
        stakingManager.getUnstakedFunds();

        // 5. Verify attester is fully removed
        assertEq(stakingManager.getActivatedAttesterCount(), 0, "attester should be removed");

        // 6. Re-add same key to registry (should succeed — cleared on dequeue)
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        // 7. Re-stake same attester (should succeed — attester was removed from StakingManager)
        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        uint256 staked = stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();

        assertEq(staked, ACTIVATION_THRESHOLD, "restake should succeed");
        assertEq(stakingManager.getActivatedAttesterCount(), 1, "attester should be active again");

        IStakingManager.StakingState memory state = stakingManager.getStakingState();
        assertEq(state.stakedAmount, ACTIVATION_THRESHOLD, "stakedAmount should reflect single stake");
    }
}
