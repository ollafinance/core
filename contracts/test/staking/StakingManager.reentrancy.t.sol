// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MaliciousAztecRollup } from "src/staking/mocks/MaliciousAztecRollup.sol";
import { MaliciousRewardsVault } from "src/core/mocks/MaliciousRewardsVault.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

contract StakingManagerReentrancyTest is Test {
    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;

    MockAztec internal aztec;
    MaliciousAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    MaliciousRewardsVault internal rewardsVault;
    StakingManager internal stakingManager;

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
        rewardsVault = new MaliciousRewardsVault(IERC20(address(aztec)), core);

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

        vm.startPrank(defaultAdmin);
        stakingManager.grantRole(stakingManager.CORE_ROLE(), address(rollup));
        stakingManager.grantRole(stakingManager.CORE_ROLE(), address(rewardsVault));
        vm.stopPrank();

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
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);
        vm.prank(core);
        stakingManager.stake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_Stake_ReenteredFromRollupDeposit() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        rollup.setReentry(address(stakingManager), abi.encodeCall(stakingManager.stake, (ACTIVATION_THRESHOLD)));
        rollup.setReenterOnDeposit(true);

        vm.prank(core);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakingManager.stake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_Unstake_ReenteredFromRollupInitiateWithdraw() external {
        _stakeOne();

        rollup.setReentry(address(stakingManager), abi.encodeCall(stakingManager.unstake, (ACTIVATION_THRESHOLD)));
        rollup.setReenterOnInitiateWithdraw(true);

        vm.prank(core);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakingManager.unstake(ACTIVATION_THRESHOLD);
    }

    function test_RevertWhen_GetUnstakedFunds_ReenteredFromRollupFinalizeWithdraw() external {
        _stakeOne();

        vm.prank(core);
        stakingManager.unstake(ACTIVATION_THRESHOLD);

        rollup.setReentry(address(stakingManager), abi.encodeCall(stakingManager.getUnstakedFunds, ()));
        rollup.setReenterOnFinalizeWithdraw(true);

        vm.prank(core);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakingManager.getUnstakedFunds();
    }

    function test_RevertWhen_CleanActivatedAttesters_ReenteredFromRollupDeposit() external {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingManager.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        rollup.setReentry(address(stakingManager), abi.encodeCall(stakingManager.cleanActivatedAttesters, ()));
        rollup.setReenterOnDeposit(true);

        vm.prank(core);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakingManager.stake(ACTIVATION_THRESHOLD);
    }
}
