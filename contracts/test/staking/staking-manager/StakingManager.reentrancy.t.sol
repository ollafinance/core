// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MaliciousAztecRollup } from "src/staking/mocks/MaliciousAztecRollup.sol";
import { MaliciousRewardsAccumulator } from "src/core/mocks/MaliciousRewardsAccumulator.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

contract StakingManagerReentrancyTest is Test {
    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;

    MockAztec internal aztec;
    MaliciousAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    MaliciousRewardsAccumulator internal rewardsAccumulator;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;

    address internal core;
    address internal providerAdmin;
    address internal defaultAdmin;

    function setUp() external {
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");

        aztec = new MockAztec(address(this));
        rollup = new MaliciousAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));
        rewardsAccumulator = new MaliciousRewardsAccumulator(IERC20(address(aztec)), core);

        // Deploy StakingManager behind proxy
        StakingManager stakingManagerImpl = new StakingManager();
        ERC1967Proxy stakingManagerProxy = new ERC1967Proxy(address(stakingManagerImpl), "");
        stakingManager = StakingManager(address(stakingManagerProxy));

        // Deploy StakingProviderRegistry behind proxy
        StakingProviderRegistry registryImpl = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImpl), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        // Initialize StakingProviderRegistry first
        stakingProviderRegistry.initialize(address(stakingManager), providerAdmin, providerAdmin, defaultAdmin);

        // Initialize StakingManager
        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsAccumulator),
            core,
            address(stakingProviderRegistry),
            defaultAdmin
        );

        vm.prank(core);
        aztec.approve(address(stakingManager), type(uint256).max);
    }

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
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

    function _stakeOne() internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.prank(core);
        stakingManager.stake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_Stake_ReenteredFromRollupDeposit() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        rollup.setReentry(address(stakingManager), abi.encodeCall(stakingManager.stake, (ACTIVATION_THRESHOLD)));
        rollup.setReenterOnDeposit(true);

        vm.prank(core);
        // Note: onlyCore modifier runs before nonReentrant, so reentrancy attempt fails with UnauthorizedCore
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, address(rollup))
        );
        stakingManager.stake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_Unstake_ReenteredFromRollupInitiateWithdraw() external {
        _stakeOne();

        rollup.setReentry(address(stakingManager), abi.encodeCall(stakingManager.unstake, (ACTIVATION_THRESHOLD)));
        rollup.setReenterOnInitiateWithdraw(true);

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(IStakingManager.StakingManager__UnauthorizedCore.selector, address(rollup))
        );
        stakingManager.unstake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_RefreshAttesterState_ReenteredFromRollupFinalizeWithdraw() external {
        _stakeOne();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        // Build attester address array for refreshAttesterState
        address[] memory attesters = new address[](1);
        attesters[0] = address(uint160(1));

        rollup.setReentry(address(stakingManager), abi.encodeCall(stakingManager.refreshAttesterState, (attesters)));
        rollup.setReenterOnFinalizeWithdraw(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakingManager.refreshAttesterState(attesters);
    }
}
