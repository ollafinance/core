// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStakingProviderRegistry } from "src/staking/interfaces/IStakingProviderRegistry.sol";

import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";

contract UnstakeRevertingStakingManager is IStakingManager {
    IERC20 public immutable STAKING_ASSET;

    uint256 public staked;
    uint256 public pending;
    uint256 public claimable;
    uint256 public slashing;

    ProviderConfig internal _providerConfig;

    constructor(IERC20 stakingAsset_) {
        STAKING_ASSET = stakingAsset_;
    }

    function setClaimableRewards(uint256 value) external {
        claimable = value;
    }

    function setSlashingDelta(uint256 value) external {
        slashing = value;
    }

    function setPendingUnstakes(uint256 value) external {
        pending = value;
    }

    function setProviderConfig(address admin, address rewardsRecipient) external {
        _providerConfig = ProviderConfig({ admin: admin, rewardsRecipient: rewardsRecipient });
    }

    function initialize(IERC20, address, address, address, address, address) external pure override { }

    function stake(uint256 amount) external override returns (uint256 stakedAmount) {
        STAKING_ASSET.transferFrom(msg.sender, address(this), amount);
        staked += amount;
        return amount;
    }

    function unstake(uint256 amount) external override {
        if (amount > staked) {
            revert StakingManager__InsufficientStake();
        }
        staked -= amount;
    }

    function cleanActivatedAttesters() external pure override { }

    function getUnstakedFunds() external pure override returns (uint256 received) {
        return 0;
    }

    function harvestRewards() external pure override returns (uint256 harvested) {
        return 0;
    }

    function getSlashingDelta() external override returns (uint256 slashingDelta) {
        return slashing;
    }

    function getClaimableRewards() external view override returns (uint256 claimableRewards) {
        return claimable;
    }

    function totalStaked() external view override returns (uint256 stakedTotal) {
        return staked;
    }

    function getStakingState() external view override returns (StakingState memory state) {
        return StakingState({ stakedAmount: staked, pendingUnstakeAmount: pending, withdrawableAmount: 0 });
    }

    function pendingUnstakes() external view override returns (uint256 pendingUnstakeAmount) {
        return pending;
    }

    function getProviderConfig() external view override returns (ProviderConfig memory) {
        return _providerConfig;
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

    function core() external pure override returns (address) {
        return address(0);
    }

    function stakingProviderRegistry() external pure override returns (IStakingProviderRegistry) {
        return IStakingProviderRegistry(address(0));
    }
}

contract OllaCoreRewardsLiquidityHappyCaseTest is Test {
    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    UnstakeRevertingStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;

    address internal governance;
    address internal alice;

    function setUp() external {
        asset = new MockAztec(address(this));
        stakingManager = new UnstakeRevertingStakingManager(asset);

        governance = makeAddr("governance");
        alice = makeAddr("alice");

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(governance, address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();

        vault.initialize(
            asset,
            IStAztec(address(stAztec)),
            IStakingManager(address(stakingManager)),
            0,
            0,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        // Allow this test contract to call operator hooks.
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();
    }

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function test_HappyCase_RebalanceHandlesWithdrawalsBackedByRewardsVaultLiquidity() external {
        uint256 principal = 200_000 * DECIMALS;
        _deposit(alice, principal);

        // Stake everything so buffered liquidity is zero.
        vault.rebalance();
        assertEq(vault.accountingState().bufferedAssets, 0, "buffer should be zero after stake");

        // Simulate rewards sitting in the rewards vault (counted in totalAssets via accounting).
        uint256 rewards = 69 * DECIMALS;
        asset.mint(address(rewardsVault), rewards);

        // Persist rewardsVaultBalance into accounting so exchangeRate/totalAssets includes it.
        vault.updateAccounting();

        // Request redeem of all shares; assetsExpected includes rewards.
        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        // Happy-case expectation: rebalance should use rewards-vault funds as liquidity and avoid over-unstaking.
        // Current implementation reverts (insufficient stake) because _initiateUnstake sizes against bufferedAssets only.
        vault.rebalance();
    }

    function test_HappyCase_RebalanceHandlesWithdrawalsBackedByClaimableRewards() external {
        uint256 principal = 200_000 * DECIMALS;
        _deposit(alice, principal);

        vault.rebalance();
        assertEq(vault.accountingState().bufferedAssets, 0, "buffer should be zero after stake");

        // Simulate claimable rewards being included in totalAssets.
        uint256 claimableRewards = 69 * DECIMALS;
        stakingManager.setClaimableRewards(claimableRewards);
        vault.updateAccounting();

        uint256 shares = stAztec.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        // Happy-case expectation: rebalance should not over-request unstake when withdrawals include claimable rewards.
        vault.rebalance();
    }
}
