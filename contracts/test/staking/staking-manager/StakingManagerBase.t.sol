// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";
import { StdStorage, stdStorage } from "@forge-std/StdStorage.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

abstract contract StakingManagerBaseTest is Test {
    using stdStorage for StdStorage;
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant ACTIVATION_THRESHOLD = 100 ether;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    MockAztec internal aztec;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;

    address internal core;
    address internal providerAdmin;
    MockRewardsVault internal rewardsVault;
    address internal defaultAdmin;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProviderSet(address indexed admin, address indexed rewardsRecipient);
    event KeysAddedToProvider(address[] attesters);
    event StakedWithProvider(address indexed attester, uint256 indexed amount);
    event UnstakeInitiated(address indexed attester, uint256 indexed amount);
    event UnstakeFinalized(address indexed attester, uint256 indexed amount);
    event UnstakedFundsClaimed(uint256 indexed amount);
    event RewardsHarvested(uint256 indexed amount);
    event QueueDripped(address indexed attester);
    event AttesterRewardsClaimed(address indexed attester, uint256 indexed amount);
    event RewardClaimFailed(address indexed attester, string reason);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        core = makeAddr("core");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        aztec = new MockAztec(address(this));
        rollup = new MockAztecRollup(IERC20(address(aztec)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));
        rewardsVault = new MockRewardsVault(IERC20(address(aztec)), core);

        StakingManager implementation = new StakingManager();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        stakingManager = StakingManager(address(proxy));

        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        stakingProviderRegistry.initialize(
            address(stakingManager),
            providerAdmin,
            providerAdmin, // rewardsRecipient same as admin for simplicity
            defaultAdmin
        );

        stakingManager.initialize(
            IERC20(address(aztec)),
            address(rollupRegistry),
            address(rewardsVault),
            core,
            address(stakingProviderRegistry),
            defaultAdmin
        );
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createMockKeys(uint256 count) internal pure returns (IStakingManager.KeyStore[] memory) {
        IStakingManager.KeyStore[] memory keys = new IStakingManager.KeyStore[](count);
        for (uint256 i; i < count; ++i) {
            keys[i] = IStakingManager.KeyStore({
                // casting to uint160 is safe because i + 1 stays within 160 bits
                // forge-lint: disable-next-line(unsafe-typecast)
                attester: address(uint160(i + 1)),
                publicKeyG1: G1Point({ x: i, y: i + 1 }),
                publicKeyG2: G2Point({ x0: i, x1: i + 1, y0: i + 2, y1: i + 3 }),
                proofOfPossession: G1Point({ x: i + 10, y: i + 11 })
            });
        }
        return keys;
    }

    function _setupStakedAttester() internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(1);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD);
        stakingManager.stake(ACTIVATION_THRESHOLD);
        vm.stopPrank();
    }

    function _setupMultipleStakedAttesters(uint256 count) internal {
        IStakingManager.KeyStore[] memory keys = _createMockKeys(count);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        uint256 stakeAmount = ACTIVATION_THRESHOLD * count;
        aztec.mint(core, stakeAmount);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), stakeAmount);
        stakingManager.stake(stakeAmount);
        vm.stopPrank();
    }

    function _setupStakedAttestersWithExits(uint256 total, uint256 exited) internal {
        require(exited <= total, "exited cannot be more than total");
        IStakingManager.KeyStore[] memory keys = _createMockKeys(total);
        vm.prank(providerAdmin);
        stakingProviderRegistry.addKeysToProvider(keys);

        aztec.mint(core, ACTIVATION_THRESHOLD * total);

        vm.startPrank(core);
        aztec.approve(address(stakingManager), ACTIVATION_THRESHOLD * total);
        stakingManager.stake(ACTIVATION_THRESHOLD * total);
        vm.stopPrank();

        // Simulate external exits for the first 'exited' attesters
        for (uint256 i; i < exited; ++i) {
            rollup.setExternalExit(keys[i].attester, ACTIVATION_THRESHOLD, block.timestamp);
        }
    }

    function _getActiveSyncCursor() internal returns (uint256) {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 activeSyncCursorSlot = bytes32(cursorSlot + 2);
        return uint256(vm.load(address(stakingManager), activeSyncCursorSlot));
    }

    function _setActiveSyncCursor(uint256 value) internal {
        uint256 cursorSlot = stdstore.target(address(stakingManager)).sig("getUnstakeCursor()").find();
        bytes32 activeSyncCursorSlot = bytes32(cursorSlot + 2);
        vm.store(address(stakingManager), activeSyncCursorSlot, bytes32(value));
    }
}
