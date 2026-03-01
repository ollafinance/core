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
import { IRewardsCollector } from "src/core/interfaces/IRewardsCollector.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MaliciousAztec } from "src/staking/mocks/MaliciousAztec.sol";
import { MaliciousRewardsCollector } from "src/core/mocks/MaliciousRewardsCollector.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MaliciousSafetyModule } from "src/safetymodule/mocks/MaliciousSafetyModule.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { MaliciousWithdrawalQueue } from "src/vault/mocks/MaliciousWithdrawalQueue.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";

/// @notice Mock staking manager that returns configurable harvested rewards.
contract MockHarvestStakingManager is IStakingManager {
    IERC20 public rewardsToken;
    address public rewardsCollector;
    uint256 public harvestedRewards;
    uint256 private _attesterStateLastUpdated = 1;
    uint256 private _attesterStateMaxAge = type(uint256).max;

    function setRewardsToken(IERC20 token) external {
        rewardsToken = token;
    }

    function setRewardsCollector(address vault) external {
        rewardsCollector = vault;
    }

    function setHarvestedRewards(uint256 value) external {
        harvestedRewards = value;
    }

    function harvestRewards() external override returns (uint256 harvested) {
        harvested = harvestedRewards;
        // Actually transfer tokens to rewards vault to simulate real harvest
        if (harvested > 0 && address(rewardsToken) != address(0) && rewardsCollector != address(0)) {
            // Cast to MockAztec/MaliciousAztec and mint tokens to this contract first, then transfer to vault
            MockAztec(address(rewardsToken)).mint(address(this), harvested);
            rewardsToken.transfer(rewardsCollector, harvested);
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

    function finalizeExits() external pure override returns (uint256) {
        return 0;
    }

    function getUnstakedFunds() external pure override returns (uint256, uint256, bool) {
        return (0, 0, false);
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
        return StakingState({ slashingDelta: 0, stakedAmount: 0, pendingUnstakeAmount: 0, withdrawableAmount: 0 });
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
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    MaliciousWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal rewardsCollector;
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
        rewardsCollector = makeAddr("rewardsCollector");
        safetyModule = new MockSafetyModule(address(implementation), address(vault));
        withdrawalQueue = new MaliciousWithdrawalQueue();

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
            governance,
            IRewardsCollector(rewardsCollector),
            address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();
        withdrawalQueue.initialize(address(vault), governance, 180_000);

        vm.startPrank(governance);
        core.grantRole(core.OPERATOR_ROLE(), address(withdrawalQueue));
        vm.stopPrank();

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

    /*//////////////////////////////////////////////////////////////
                            REQUEST REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestRedeem_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        withdrawalQueue.setReentry(
            address(vault), abi.encodeWithSignature("requestRedeem(uint256,address,address)", shares, bob, alice)
        );
        withdrawalQueue.setReenterOnRequest(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.requestRedeem(shares, bob, alice);
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM REQUEST
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ClaimRequestById_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob, alice);

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
        uint256 requestId = vault.requestRedeem(shares, bob, alice);

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
        vault.requestRedeem(shares, bob, alice);

        withdrawalQueue.setReentry(address(core), abi.encodeCall(core.rebalance, ()));
        withdrawalQueue.setReenterOnFinalize(true);

        vm.expectRevert();
        vm.prank(governance);
        core.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                          INSTANT REDEMPTION (FEE PATH)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_ReenteredFromFeeTransfer() external {
        _deposit(alice, 100 * DECIMALS);

        uint256 sharesToRedeem = 10 * DECIMALS;

        // Skip first transfer (net assets to recipient), fire re-entry on second (fee to governance)
        asset.setTransferReentrySkipCount(1);
        asset.configureTransferReentry(
            address(vault), abi.encodeCall(vault.instantRedeem, (sharesToRedeem, bob, 0)), true
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.instantRedeem(sharesToRedeem, bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     INSTANT REDEMPTION WITH PERMIT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RedeemWithPermit_ReenteredFromTransferHook() external {
        _deposit(permitOwner, 100 * DECIMALS);

        uint256 sharesToRedeem = 10 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(permitOwner, permitOwnerKey, address(vault), sharesToRedeem, deadline);

        asset.configureTransferReentry(
            address(vault), abi.encodeCall(vault.instantRedeem, (sharesToRedeem, bob, 0)), true
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(permitOwner);
        vault.instantRedeemWithPermit(sharesToRedeem, bob, 0, deadline, v, r, s);
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
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockHarvestStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    MockWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    MaliciousRewardsCollector internal rewardsCollector;
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
        rewardsCollector = new MaliciousRewardsCollector(asset, address(core));
        safetyModule = new MockSafetyModule(address(implementation), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        // Configure staking manager to mint rewards directly to rewards vault
        stakingManager.setRewardsToken(IERC20(address(asset)));
        stakingManager.setRewardsCollector(address(rewardsCollector));

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
            governance,
            IRewardsCollector(address(rewardsCollector)),
            address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        vm.startPrank(governance);
        core.grantRole(core.OPERATOR_ROLE(), governance);
        core.grantRole(core.OPERATOR_ROLE(), address(rewardsCollector));
        vm.stopPrank();

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

    function test_RevertWhen_Rebalance_ReenteredFromRewardsCollectorHook() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        rewardsCollector.configureReentry(address(core), abi.encodeCall(core.rebalance, ()), true);

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
    MockWithdrawalQueue internal withdrawalQueue;
    address internal governance;
    address internal rewardsCollector;
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
        rewardsCollector = makeAddr("rewardsCollector");
        safetyModule = new MaliciousSafetyModule(address(implementation), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, IRewardsCollector(rewardsCollector), address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        vm.startPrank(governance);
        core.grantRole(core.OPERATOR_ROLE(), governance);
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
        vault.deposit(assets, owner, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         UPDATE ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UpdateAccounting_ReenteredFromSafetyModuleCheck() external {
        _deposit(alice, 10 * DECIMALS);

        // Re-entry targets updateAccounting() on core — same nonReentrant guard applies
        safetyModule.setReentry(address(core), abi.encodeCall(core.updateAccounting, ()));
        safetyModule.setReenterOnCheckAccountingLiveness(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(governance);
        core.updateAccounting();
    }
}
