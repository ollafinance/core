// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MaliciousAztec } from "src/staking/mocks/MaliciousAztec.sol";
import { MaliciousRewardsAccumulator } from "src/core/mocks/MaliciousRewardsAccumulator.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MaliciousSafetyModule } from "src/safetymodule/mocks/MaliciousSafetyModule.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";

/// @notice Mock staking manager that returns configurable harvested rewards.
contract MockHarvestStakingManager is IStakingManager {
    IERC20 public rewardsToken;
    address public rewardsAccumulator;
    uint256 public harvestedRewards;

    function setRewardsToken(IERC20 token) external {
        rewardsToken = token;
    }

    function setRewardsAccumulator(address vault) external {
        rewardsAccumulator = vault;
    }

    function setHarvestedRewards(uint256 value) external {
        harvestedRewards = value;
    }

    function harvestRewards() external override returns (uint256 harvested) {
        harvested = harvestedRewards;
        if (harvested > 0 && address(rewardsToken) != address(0) && rewardsAccumulator != address(0)) {
            MockAztec(address(rewardsToken)).mint(address(this), harvested);
            rewardsToken.transfer(rewardsAccumulator, harvested);
        }
        return harvested;
    }

    function core() external pure override returns (address) {
        return address(0);
    }

    function canStake(uint256) external pure override returns (bool) {
        return false;
    }

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }

    function setGasThreshold(uint256) external override { }

    function stake(uint256) external pure override returns (uint256) {
        return 0;
    }

    function unstake(uint256) external pure override returns (uint256) {
        return 0;
    }

    function refreshAttesterState(address[] calldata) external override { }

    function purgeFailedQueueEntry(address) external override { }

    function getUnstakedFunds() external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function getClaimableRewards() external pure override returns (uint256) {
        return 0;
    }

    function getSlashingDelta() external pure override returns (uint256) {
        return 0;
    }

    function totalStaked() external pure override returns (uint256) {
        return 0;
    }

    function getStakingState() external pure override returns (StakingState memory) {
        return StakingState({ slashingDelta: 0, stakedAmount: 0, pendingUnstakeAmount: 0 });
    }

    function pendingUnstakes() external pure override returns (uint256) {
        return 0;
    }

    function hasFinalizedUnstakes() external pure override returns (bool) {
        return false;
    }

    function claimableUnstakedFunds() external pure override returns (uint256) {
        return 0;
    }

    function getProviderConfig() external pure override returns (ProviderConfig memory) {
        return ProviderConfig({ rewardsRecipient: address(0) });
    }

    function getActivatedAttesterCount() external pure override returns (uint256) {
        return 0;
    }

    function getPendingUnstakeCount() external pure override returns (uint256) {
        return 0;
    }

    function isUnstakePending(address) external pure override returns (bool) {
        return false;
    }

    function initialize(IERC20, address, address, address, address, address) external pure override { }
}

contract OllaCoreReentrancyTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MaliciousAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    MockSafetyModule internal safetyModule;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    address internal alice;
    address internal bob;
    address internal permitOwner;
    uint256 internal permitOwnerKey;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MaliciousAztec();

        OllaCore implementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(implementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(IERC20(address(asset)), address(core));
        safetyModule = new MockSafetyModule(address(implementation), address(vault));

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
            governance,
            IRewardsAccumulator(address(rewardsAccumulator)),
            address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        permitOwnerKey = 0xA11CE;
        permitOwner = vm.addr(permitOwnerKey);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        vault.deposit(assets, owner, 0);
    }

    function _signPermit(address owner, uint256 ownerKey, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 domainSeparator = stAztec.DOMAIN_SEPARATOR();
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, owner, spender, value, stAztec.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Deposit_ReenteredFromTransferFrom() external {
        uint256 assets = 5 * DECIMALS;

        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        asset.mint(address(asset), assets);
        asset.setSelfAllowance(assets);
        asset.configureReentry(
            address(vault),
            abi.encodeWithSelector(bytes4(keccak256("deposit(uint256,address,uint256)")), assets, alice, 0),
            true
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(assets, alice, 0);
    }

    // Queue-based reentrancy tests (request/claim/rebalance) were removed when WithdrawalQueue
    // was folded into OllaVault: the merged paths make no external CALL with untrusted control
    // flow, so there is no entrypoint left for the queue-mock reentry hooks to fire from.
}

contract OllaCoreHarvestReentrancyTest is Test {
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
    MockHarvestStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    MockSafetyModule internal safetyModule;
    MaliciousRewardsAccumulator internal rewardsAccumulator;
    address internal governance;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(implementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockHarvestStakingManager();
        rewardsAccumulator = new MaliciousRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(implementation), address(vault));

        // Configure staking manager to mint rewards directly to rewards vault
        stakingManager.setRewardsToken(IERC20(address(asset)));
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
            governance,
            IRewardsAccumulator(address(rewardsAccumulator)),
            address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");

        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        vault.deposit(assets, owner, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             REBALANCE HARVEST
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Rebalance_ReenteredFromRewardsAccumulatorHook() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        rewardsAccumulator.configureReentry(address(core), abi.encodeCall(core.rebalance, ()), true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(governance);
        core.rebalance();
    }
}

contract OllaCoreUpdateAccountingReentrancyTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MaliciousAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    MaliciousSafetyModule internal safetyModule;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MaliciousAztec();

        OllaCore implementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(implementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(IERC20(address(asset)), address(core));
        safetyModule = new MaliciousSafetyModule(address(implementation), address(vault));

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            500,
            5_000,
            governance,
            IRewardsAccumulator(address(rewardsAccumulator)),
            address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        vault.deposit(assets, owner, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         UPDATE ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UpdateAccounting_ReenteredFromSafetyModuleCheck() external {
        _deposit(alice, 10 * DECIMALS);

        // Re-entry targets updateAccounting() on core -- same nonReentrant guard applies
        safetyModule.setReentry(address(core), abi.encodeCall(core.updateAccounting, ()));
        safetyModule.setReenterOnCheckAccountingLiveness(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(governance);
        core.updateAccounting();
    }
}
