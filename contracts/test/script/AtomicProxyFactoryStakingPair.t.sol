// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { AccessControlUpgradeable } from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { AtomicProxyFactory } from "script/deployers/AtomicProxyFactory.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IAztecRewardDistributor } from "src/staking/interfaces/IAztecRewardDistributor.sol";
import { IAztecRollupRegistry } from "src/staking/interfaces/IAztecRollupRegistry.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";

/// @title AtomicProxyFactoryStakingPairTest
/// @notice Regression suite for the v1.1 mainnet initialize front-run incident (2026-05-11).
/// The previous StakingStack deployment script deployed the two staking proxies in separate
/// broadcast transactions and only initialized them in later transactions, leaving a
/// multi-block window where a mempool bot could call initialize() ahead of governance.
/// AtomicProxyFactory.deployStakingPairAndInitialize replaces that flow with a single
/// external call that deploys both proxies and runs both initializers in the same call
/// frame, so the pair is never observable in an uninitialized state.
contract AtomicProxyFactoryStakingPairTest is Test {
    bytes32 internal constant _SM_SALT = keccak256("test.staking.manager.salt");
    bytes32 internal constant _SPR_SALT = keccak256("test.staking.provider.registry.salt");

    AtomicProxyFactory internal _factory;
    StakingManager internal _smImpl;
    StakingProviderRegistry internal _sprImpl;

    address internal _deployer = makeAddr("deployer");
    address internal _governance = makeAddr("governance");
    address internal _providerAdmin = makeAddr("providerAdmin");
    address internal _providerRewardsRecipient = makeAddr("providerRewardsRecipient");
    address internal _asset = makeAddr("asset");
    address internal _rollupRegistry = makeAddr("rollupRegistry");
    address internal _rewardsAccumulator = makeAddr("rewardsAccumulator");
    address internal _core = makeAddr("core");

    function setUp() external {
        _factory = new AtomicProxyFactory(_deployer);
        _smImpl = new StakingManager();
        _sprImpl = new StakingProviderRegistry();

        // Stub the staking-asset-vs-reward-asset coherency check that StakingManager.initialize
        // performs via rollupRegistry.getRewardDistributor().ASSET(). The factory is the unit
        // under test, not rollup-registry semantics, so we mock these external reads.
        address rewardDistributor = makeAddr("rewardDistributor");
        address canonicalRollup = makeAddr("canonicalRollup");
        vm.mockCall(
            _rollupRegistry, abi.encodeCall(IAztecRollupRegistry.getCanonicalRollup, ()), abi.encode(canonicalRollup)
        );
        vm.mockCall(
            _rollupRegistry,
            abi.encodeCall(IAztecRollupRegistry.getRewardDistributor, ()),
            abi.encode(rewardDistributor)
        );
        vm.mockCall(rewardDistributor, abi.encodeCall(IAztecRewardDistributor.ASSET, ()), abi.encode(_asset));
    }

    function test_deployStakingPair_initializesBothAtomically() external {
        address predictedSm = _factory.computeAddress(address(_smImpl), _SM_SALT);
        address predictedSpr = _factory.computeAddress(address(_sprImpl), _SPR_SALT);

        vm.prank(_deployer);
        (address smProxy, address sprProxy) = _deployPair();

        assertEq(smProxy, predictedSm, "manager proxy must match CREATE2 prediction");
        assertEq(sprProxy, predictedSpr, "registry proxy must match CREATE2 prediction");

        // Cross-references wired
        assertEq(address(StakingManager(smProxy).stakingProviderRegistry()), sprProxy, "manager.registry");
        assertEq(StakingProviderRegistry(sprProxy).stakingManager(), smProxy, "registry.manager");

        // Init params landed
        assertEq(address(StakingManager(smProxy).stakingAsset()), _asset, "manager.asset");
        assertEq(address(StakingManager(smProxy).rollupRegistry()), _rollupRegistry, "manager.rollupRegistry");
        assertEq(StakingManager(smProxy).rewardsAccumulator(), _rewardsAccumulator, "manager.rewardsAccumulator");
        assertEq(StakingManager(smProxy).core(), _core, "manager.core");

        // Governance admin role granted on both proxies
        assertTrue(AccessControlUpgradeable(smProxy).hasRole(bytes32(0), _governance), "manager governance admin");
        assertTrue(AccessControlUpgradeable(sprProxy).hasRole(bytes32(0), _governance), "registry governance admin");

        // Re-initialization is rejected on both proxies. This is the property that closes the
        // front-run window: if an attacker somehow squeezed in between deploy and initialize,
        // their initialize() call would succeed; here we prove the factory leaves no such gap
        // by demonstrating the proxies are already fully initialized after the single call.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StakingManager(smProxy)
            .initialize(IERC20(_asset), _rollupRegistry, _rewardsAccumulator, _core, sprProxy, _governance);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StakingProviderRegistry(sprProxy).initialize(smProxy, _providerAdmin, _providerRewardsRecipient, _governance);
    }

    function test_deployStakingPair_revertsForUnauthorizedCaller() external {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(AtomicProxyFactory.AtomicProxyFactory__UnauthorizedCaller.selector, attacker)
        );
        _deployPair();
    }

    function test_deployStakingPair_revertsForZeroStakingManagerImpl() external {
        vm.prank(_deployer);
        vm.expectRevert(
            abi.encodeWithSelector(AtomicProxyFactory.AtomicProxyFactory__ZeroAddress.selector, "stakingManagerImpl")
        );
        _factory.deployStakingPairAndInitialize(
            address(0),
            address(_sprImpl),
            _SM_SALT,
            _SPR_SALT,
            IERC20(_asset),
            _rollupRegistry,
            IRewardsAccumulator(_rewardsAccumulator),
            _core,
            _providerAdmin,
            _providerRewardsRecipient,
            _governance
        );
    }

    function test_deployStakingPair_revertsForZeroStakingProviderRegistryImpl() external {
        vm.prank(_deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AtomicProxyFactory.AtomicProxyFactory__ZeroAddress.selector, "stakingProviderRegistryImpl"
            )
        );
        _factory.deployStakingPairAndInitialize(
            address(_smImpl),
            address(0),
            _SM_SALT,
            _SPR_SALT,
            IERC20(_asset),
            _rollupRegistry,
            IRewardsAccumulator(_rewardsAccumulator),
            _core,
            _providerAdmin,
            _providerRewardsRecipient,
            _governance
        );
    }

    function _deployPair() internal returns (address smProxy, address sprProxy) {
        return _factory.deployStakingPairAndInitialize(
            address(_smImpl),
            address(_sprImpl),
            _SM_SALT,
            _SPR_SALT,
            IERC20(_asset),
            _rollupRegistry,
            IRewardsAccumulator(_rewardsAccumulator),
            _core,
            _providerAdmin,
            _providerRewardsRecipient,
            _governance
        );
    }
}
