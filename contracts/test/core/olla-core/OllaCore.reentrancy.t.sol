// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MaliciousAztec } from "src/staking/mocks/MaliciousAztec.sol";
import { MaliciousRewardsVault } from "src/core/mocks/MaliciousRewardsVault.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { MaliciousAztec } from "src/staking/mocks/MaliciousAztec.sol";
import { MaliciousWithdrawalQueue } from "src/core/mocks/MaliciousWithdrawalQueue.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Mock staking manager that returns configurable harvested rewards.
contract MockHarvestStakingManager is IStakingManager {
    IERC20 public rewardsToken;
    address public rewardsVault;
    uint256 public harvestedRewards;
    uint256 private _attesterStateLastUpdated = 1;
    uint256 private _attesterStateMaxAge = type(uint256).max;

    function setRewardsToken(IERC20 token) external {
        rewardsToken = token;
    }

    function setRewardsVault(address vault) external {
        rewardsVault = vault;
    }

    function setHarvestedRewards(uint256 value) external {
        harvestedRewards = value;
    }

    function harvestRewards() external override returns (uint256 harvested) {
        harvested = harvestedRewards;
        // Actually transfer tokens to rewards vault to simulate real harvest
        if (harvested > 0 && address(rewardsToken) != address(0) && rewardsVault != address(0)) {
            // Cast to MockAztec/MaliciousAztec and mint tokens to this contract first, then transfer to vault
            MockAztec(address(rewardsToken)).mint(address(this), harvested);
            rewardsToken.transfer(rewardsVault, harvested);
        }
        return harvested;
    }

    function core() external pure override returns (address) {
        return address(0);
    }

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }

    function stake(uint256) external pure override returns (uint256) {
        return 0;
    }

    function setGasThreshold(uint256 threshold) external pure override {
        threshold;
    }

    function unstake(uint256) external pure override returns (uint256) {
        return 0;
    }

    function getUnstakedFunds() external pure override returns (uint256) {
        return 0;
    }

    function getClaimableRewards() external pure override returns (uint256) {
        return 0;
    }

    function getSlashingDelta() external view override returns (uint256) {
        if (_isAttesterStateStale()) {
            revert StakingManager__AttesterStateStale(_attesterStateLastUpdated, _attesterStateMaxAge);
        }
        return 0;
    }

    function computeAttesterState() external override returns (uint256 slashingDelta, bool completed) {
        uint256 lastUpdated = _attesterStateLastUpdated;
        bool wasStale = _isAttesterStateStale();

        _attesterStateLastUpdated = block.timestamp;
        emit AttesterStateUpdated(0, 0, 0, 0, block.timestamp);
        if (wasStale) {
            emit AttesterStateStale(lastUpdated, _attesterStateMaxAge);
        }

        return (0, true);
    }

    function setAttesterStateMaxAge(uint256 maxAge) external override {
        if (maxAge == 0) {
            revert StakingManager__ZeroAmount();
        }
        _attesterStateMaxAge = maxAge;
    }

    function totalStaked() external pure override returns (uint256) {
        return 0;
    }

    function getStakingState() external pure override returns (StakingState memory) {
        return StakingState({ stakedAmount: 0, pendingUnstakeAmount: 0, withdrawableAmount: 0 });
    }

    function pendingUnstakes() external pure override returns (uint256) {
        return 0;
    }

    function hasExitableUnstakes() external pure override returns (bool) {
        return false;
    }

    function getProviderConfig() external pure override returns (ProviderConfig memory) {
        return ProviderConfig({ admin: address(0), rewardsRecipient: address(0) });
    }

    function getAttesterStateLiveness()
        external
        view
        override
        returns (uint256 lastUpdated, uint256 maxAge, bool isStale)
    {
        lastUpdated = _attesterStateLastUpdated;
        maxAge = _attesterStateMaxAge;
        isStale = _isAttesterStateStale();
        return (lastUpdated, maxAge, isStale);
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

    function getUnstakeCursor() external pure override returns (uint256) {
        return 0;
    }

    function initialize(IERC20, address, address, address, address, address) external pure override { }

    function _isAttesterStateStale() internal view returns (bool) {
        uint256 lastUpdated = _attesterStateLastUpdated;
        if (lastUpdated == 0) {
            return true;
        }
        return block.timestamp - lastUpdated > _attesterStateMaxAge;
    }
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
    OllaCore internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    MaliciousWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal rewardsVault;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MaliciousAztec();

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockStakingManager();
        rewardsVault = makeAddr("rewardsVault");
        safetyModule = new MockSafetyModule(address(implementation));
        withdrawalQueue = new MaliciousWithdrawalQueue();

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
            governance,
            address(withdrawalQueue),
            IRewardsVault(rewardsVault),
            address(safetyModule)
        );
        withdrawalQueue.initialize(address(vault), governance);

        vm.startPrank(governance);
        vault.grantRole(vault.OPERATOR_ROLE(), address(withdrawalQueue));
        vm.stopPrank();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        vault.deposit(assets, owner);
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
        asset.configureReentry(address(vault), abi.encodeCall(vault.deposit, (assets, alice)), true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    /*//////////////////////////////////////////////////////////////
                            REQUEST REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestRedeem_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        withdrawalQueue.setReentry(address(vault), abi.encodeCall(vault.requestRedeem, (shares, bob)));
        withdrawalQueue.setReenterOnRequest(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.requestRedeem(shares, bob);
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM REQUEST
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ClaimRequestById_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        withdrawalQueue.setReentry(address(vault), abi.encodeCall(vault.claimRequestById, (requestId)));
        withdrawalQueue.setReenterOnClaim(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    function test_ClaimRequestById_ReentrySeesRequestCleared() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        withdrawalQueue.setReentry(address(this), abi.encodeCall(this.assertRequestCleared, (alice, requestId)));
        withdrawalQueue.setReenterOnClaim(true);

        vm.prank(alice);
        vault.claimRequestById(requestId);
    }

    function assertRequestCleared(address owner, uint256 requestId) external view {
        uint256[] memory activeRequests = vault.activeRequestIds(owner);
        require(activeRequests.length == 0, "request still active");
        require(vault.requestOwner(requestId) == address(0), "request owner not cleared");
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Rebalance_ReenteredFromQueueFinalize() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(shares, bob);

        withdrawalQueue.setReentry(address(vault), abi.encodeCall(vault.rebalance, ()));
        withdrawalQueue.setReenterOnFinalize(true);

        vm.expectRevert();
        vm.prank(governance);
        vault.rebalance();
    }
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
    OllaCore internal vault;
    StAztec internal stAztec;
    MockHarvestStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    MockWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    MaliciousRewardsVault internal rewardsVault;
    address internal governance;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockHarvestStakingManager();
        rewardsVault = new MaliciousRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(implementation));
        withdrawalQueue = new MockWithdrawalQueue();

        // Configure staking manager to mint rewards directly to rewards vault
        stakingManager.setRewardsToken(IERC20(address(asset)));
        stakingManager.setRewardsVault(address(rewardsVault));

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );

        vm.startPrank(governance);
        vault.grantRole(vault.OPERATOR_ROLE(), governance);
        vault.grantRole(vault.OPERATOR_ROLE(), address(rewardsVault));
        vm.stopPrank();

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
        vault.deposit(assets, owner);
    }

    /*//////////////////////////////////////////////////////////////
                             REBALANCE HARVEST
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Rebalance_ReenteredFromRewardsVaultHook() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        rewardsVault.configureReentry(address(vault), abi.encodeCall(vault.rebalance, ()), true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(governance);
        vault.rebalance();
    }
}
