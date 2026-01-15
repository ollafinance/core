// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { IStAztec } from "src/interfaces/IStAztec.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";

contract OllaCoreHarness is OllaCore {
    function exposedIncreaseBuffered(uint256 amount, bytes32 reason) external {
        _increaseBuffered(amount, reason);
    }

    function exposedDecreaseBuffered(uint256 amount, bytes32 reason) external {
        _decreaseBuffered(amount, reason);
    }

    function exposedIncreaseStakedPrincipal(uint256 amount, bytes32 reason) external {
        _increaseStakedPrincipal(amount, reason);
    }

    function exposedDecreaseStakedPrincipal(uint256 amount, bytes32 reason) external {
        _decreaseStakedPrincipal(amount, reason);
    }

    function exposedIncreaseRewardsVaultBalance(uint256 amount, bytes32 reason) external {
        _increaseRewardsVaultBalance(amount, reason);
    }

    function exposedSetRewardsDelta(uint256 newValue, bytes32 reason) external {
        _setRewardsDelta(newValue, reason);
    }

    function exposedSetSlashingDelta(uint256 newValue, bytes32 reason) external {
        _setSlashingDelta(newValue, reason);
    }

    function exposedStake(uint256 amount) external {
        _stake(amount);
    }

    function exposedUnstake(uint256 amount) external {
        _unstake(amount);
    }

    function exposedSyncBufferedWithBalance() external view {
        _syncBufferedWithBalance();
    }
}

contract OllaCoreUpgradeMock is OllaCore {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract OllaCoreTest is Test {
    using Math for uint256;

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event RequestWithdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event RequestRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event ClaimWithdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event ClaimRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event BucketUpdated(uint8 bucketId, uint256 oldValue, uint256 newValue, bytes32 reason);

    uint256 internal constant DECIMALS = 1e18;
    uint8 internal constant BUCKET_ID_BUFFERED = 0;
    uint8 internal constant BUCKET_ID_STAKED_PRINCIPAL = 1;
    uint8 internal constant BUCKET_ID_REWARDS_VAULT = 2;
    uint8 internal constant BUCKET_ID_REWARDS_DELTA = 3;
    uint8 internal constant BUCKET_ID_SLASHING_DELTA = 4;
    bytes32 internal constant EXPECTED_REASON_DEPOSIT = "DEPOSIT";
    bytes32 internal constant EXPECTED_REASON_CLAIM = "CLAIM";
    bytes32 internal constant EXPECTED_REASON_STAKE = "STAKE";
    bytes32 internal constant EXPECTED_REASON_SLASH = "SLASH";
    bytes32 internal constant EXPECTED_REASON_REWARD = "REWARD";

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        vault.initialize(asset, stAztec, stakingManager, governance);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function _expectBucketUpdated(uint8 bucketId, uint256 oldValue, uint256 newValue, bytes32 reason) internal {
        vm.expectEmit(true, true, true, true, address(vault));
        emit BucketUpdated(bucketId, oldValue, newValue, reason);
    }
    
    function test_InitializeSetsCoreAddresses() external {
        assertEq(vault.asset(), address(asset), "asset set");
        assertEq(vault.stAztec(), address(stAztec), "stAztec set");
        assertEq(vault.stakingManager(), address(stakingManager), "staking manager set");
        assertEq(vault.governance(), governance, "governance set");
    }

    function test_RevertWhen_Reinitialize() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(asset, stAztec, stakingManager, governance);
    }

    function test_RevertWhen_UnauthorizedUpgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();
        address attacker = makeAddr("attacker");

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreUnauthorizedGovernance.selector, attacker));
        vm.prank(attacker);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_GovernanceCanUpgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();

        vm.prank(governance);
        vault.upgradeToAndCall(address(newImplementation), "");

        uint256 version = OllaCoreUpgradeMock(address(vault)).version();
        assertEq(version, 2, "upgrade applied");
    }

    function test_DepositMintsAtExchangeRate() external {
        uint256 depositAssetAmountAlice = 100 * DECIMALS;
        uint256 firstShares = _performDeposit(alice, depositAssetAmountAlice);
        assertEq(firstShares, depositAssetAmountAlice, "first deposit: 1:1 shares at zero supply");

        vault.exposedIncreaseRewardsVaultBalance(50 * DECIMALS, EXPECTED_REASON_REWARD);

        uint256 totalAssetsBeforeSecondDeposit = vault.totalAssets();
        uint256 totalSharesBeforeSecondDeposit = stAztec.totalSupply();

        uint256 depositAssetAmountBob = 50 * DECIMALS;
        uint256 expectedShares = (depositAssetAmountBob)
        .mulDiv(totalSharesBeforeSecondDeposit, totalAssetsBeforeSecondDeposit, Math.Rounding.Floor);
        uint256 secondShares = _performDeposit(bob, depositAssetAmountBob);

        assertEq(secondShares, expectedShares, "second deposit: shares follow exchange rate");
    }

    function test_DepositsAreInstant() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);

        assertEq(stAztec.balanceOf(alice), shares, "shares minted");
        assertEq(vault.totalAssets(), 10 * DECIMALS, "assets buffered");
    }

    function test_BucketGettersReflectState() external {
        uint256 assets = 10 * DECIMALS;
        uint256 staked = 6 * DECIMALS;
        uint256 rewardsVault = 4 * DECIMALS;
        uint256 rewardsDelta = 2 * DECIMALS;
        uint256 slashingDelta = 1 * DECIMALS;

        _performDeposit(alice, assets);
        vault.exposedIncreaseStakedPrincipal(staked, EXPECTED_REASON_STAKE);
        vault.exposedIncreaseRewardsVaultBalance(rewardsVault, EXPECTED_REASON_REWARD);
        vault.exposedSetRewardsDelta(rewardsDelta, EXPECTED_REASON_REWARD);
        vault.exposedSetSlashingDelta(slashingDelta, EXPECTED_REASON_SLASH);

        assertEq(vault.bufferedAssets(), assets, "bufferedAssets matches deposited assets");
        assertEq(vault.stakedPrincipal(), staked, "stakedPrincipal matches staked amount");
        assertEq(vault.rewardsVaultBalance(), rewardsVault, "rewardsVaultBalance matches rewards vault");
        assertEq(vault.rewardsDelta(), rewardsDelta, "rewardsDelta matches rewards delta");
        assertEq(vault.slashingDelta(), slashingDelta, "slashingDelta matches slashing delta");
        assertEq(
            vault.totalAssets(),
            assets + staked + rewardsVault + rewardsDelta - slashingDelta,
            "totalAssets sums buckets"
        );
    }

    function test_BucketHelpersEmitEvents() external {
        uint256 amount = 5 * DECIMALS;

        _expectBucketUpdated(BUCKET_ID_BUFFERED, 0, amount, EXPECTED_REASON_DEPOSIT);
        vault.exposedIncreaseBuffered(amount, EXPECTED_REASON_DEPOSIT);

        _expectBucketUpdated(BUCKET_ID_BUFFERED, amount, 0, EXPECTED_REASON_CLAIM);
        vault.exposedDecreaseBuffered(amount, EXPECTED_REASON_CLAIM);

        _expectBucketUpdated(BUCKET_ID_STAKED_PRINCIPAL, 0, amount, EXPECTED_REASON_STAKE);
        vault.exposedIncreaseStakedPrincipal(amount, EXPECTED_REASON_STAKE);

        _expectBucketUpdated(BUCKET_ID_REWARDS_VAULT, 0, amount, EXPECTED_REASON_REWARD);
        vault.exposedIncreaseRewardsVaultBalance(amount, EXPECTED_REASON_REWARD);

        _expectBucketUpdated(BUCKET_ID_REWARDS_DELTA, 0, amount, EXPECTED_REASON_REWARD);
        vault.exposedSetRewardsDelta(amount, EXPECTED_REASON_REWARD);

        _expectBucketUpdated(BUCKET_ID_SLASHING_DELTA, 0, amount, EXPECTED_REASON_SLASH);
        vault.exposedSetSlashingDelta(amount, EXPECTED_REASON_SLASH);

        assertEq(vault.bufferedAssets(), 0, "bufferedAssets cleared after decrease");
        assertEq(vault.stakedPrincipal(), amount, "stakedPrincipal increased by amount");
        assertEq(vault.rewardsVaultBalance(), amount, "rewardsVaultBalance increased by amount");
        assertEq(vault.rewardsDelta(), amount, "rewardsDelta set to amount");
        assertEq(vault.slashingDelta(), amount, "slashingDelta set to amount");
    }

    function test_SyncBufferedWithBalanceAfterDepositAndClaim() external {
        uint256 assets = 10 * DECIMALS;
        uint256 claimAssets = 5 * DECIMALS;

        _performDeposit(alice, assets);
        vault.exposedSyncBufferedWithBalance();

        assertEq(vault.bufferedAssets(), assets, "buffered matches vault balance after deposit");
        assertEq(asset.balanceOf(address(vault)), assets, "vault balance matches deposit");

        vm.prank(alice);
        vault.requestRedeem(claimAssets, alice, alice);

        vm.prank(bob);
        vault.claimPendingWithdraw(alice);
        vault.exposedSyncBufferedWithBalance();

        uint256 expectedRemaining = assets - claimAssets;
        assertEq(vault.bufferedAssets(), expectedRemaining, "buffered matches vault balance after claim");
        assertEq(asset.balanceOf(address(vault)), expectedRemaining, "vault balance matches claim");
        assertEq(asset.balanceOf(alice), claimAssets, "claim transfers assets to receiver");
    }

    function test_StakingAndUnstakingDoesNotAffectBucketBalances() external {
        uint256 assets = 12 * DECIMALS;

        _performDeposit(alice, assets);

        uint256 bufferedBefore = vault.bufferedAssets();
        uint256 stakedBefore = vault.stakedPrincipal();
        uint256 rewardsVaultBefore = vault.rewardsVaultBalance();
        uint256 rewardsDeltaBefore = vault.rewardsDelta();
        uint256 slashingDeltaBefore = vault.slashingDelta();

        vault.exposedStake(assets / 2);
        vault.exposedUnstake(assets / 2);

        assertEq(vault.bufferedAssets(), bufferedBefore, "buffered unchanged");
        assertEq(vault.stakedPrincipal(), stakedBefore, "staked unchanged");
        assertEq(vault.rewardsVaultBalance(), rewardsVaultBefore, "rewards vault unchanged");
        assertEq(vault.rewardsDelta(), rewardsDeltaBefore, "rewards delta unchanged");
        assertEq(vault.slashingDelta(), slashingDeltaBefore, "slashing delta unchanged");
    }

    function testFuzz_TotalAssetsComposition(
        uint96 buffered,
        uint96 staked,
        uint96 rewardsVault,
        uint96 rewardsDelta,
        uint96 slashingDeltaSeed
    ) external {
        buffered = uint96(bound(buffered, 1, type(uint96).max));
        staked = uint96(bound(staked, 1, type(uint96).max));
        rewardsVault = uint96(bound(rewardsVault, 1, type(uint96).max));
        rewardsDelta = uint96(bound(rewardsDelta, 0, type(uint96).max));

        uint256 positiveTotal = uint256(buffered) + uint256(staked) + uint256(rewardsVault) + uint256(rewardsDelta);
        uint256 slashingDelta = bound(uint256(slashingDeltaSeed), 0, positiveTotal);

        asset.mint(address(vault), buffered);
        vault.exposedIncreaseBuffered(buffered, EXPECTED_REASON_DEPOSIT);
        vault.exposedIncreaseStakedPrincipal(staked, EXPECTED_REASON_STAKE);
        vault.exposedIncreaseRewardsVaultBalance(rewardsVault, EXPECTED_REASON_REWARD);
        vault.exposedSetRewardsDelta(rewardsDelta, EXPECTED_REASON_REWARD);
        vault.exposedSetSlashingDelta(slashingDelta, EXPECTED_REASON_SLASH);

        assertEq(vault.totalAssets(), positiveTotal - slashingDelta, "totalAssets includes slashing delta");
    }

    function test_RevertWhen_BufferedBalanceMismatch() external {
        uint256 assets = 10 * DECIMALS;
        uint256 bonus = 2 * DECIMALS;

        _performDeposit(alice, assets);
        asset.mint(address(vault), bonus);

        vm.expectRevert(
            abi.encodeWithSelector(OllaCore.OllaCoreBufferedBalanceMismatch.selector, assets, assets + bonus)
        );
        vault.exposedSyncBufferedWithBalance();
    }

    function test_EmitDepositEvent() external {
        uint256 assets = 10 * DECIMALS;

        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, alice, assets, assets);

        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    function test_EmitRequestRedeemAndClaimEvents() external {
        _performDeposit(alice, 25 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RequestRedeem(alice, bob, 5 * DECIMALS, 5 * DECIMALS);

        vm.prank(alice);
        uint256 assets = vault.requestRedeem(5 * DECIMALS, bob, alice);

        assertEq(assets, 5 * DECIMALS, "assets expected");

        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdraw(bob, bob, alice, 5 * DECIMALS, 5 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ClaimRedeem(alice, bob, 5 * DECIMALS, 5 * DECIMALS);

        vm.prank(bob);
        vault.claimPendingWithdraw(alice);
    }

    function test_RevertWhen_PendingWithdrawalExists() external {
        _performDeposit(alice, 20 * DECIMALS);

        vm.prank(alice);
        vault.requestRedeem(5 * DECIMALS, alice, alice);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCorePendingWithdrawalExists.selector, alice));
        vm.prank(alice);
        vault.requestRedeem(1 * DECIMALS, alice, alice);
    }

    function test_RevertWhen_NoPendingWithdrawal() external {
        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreNoPendingWithdrawal.selector, alice));
        vault.claimPendingWithdraw(alice);
    }

    function test_RevertWhen_InitializeZeroAddress() external {
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        OllaCore newVault = OllaCore(address(proxy));
        StAztec newStAztec = new StAztec(address(newVault));
        MockStakingManager newStakingManager = new MockStakingManager();

        address newGovernance = makeAddr("governance");

        vm.expectRevert(OllaCore.OllaCoreZeroAddress.selector);
        newVault.initialize(IERC20(address(0)), newStAztec, newStakingManager, newGovernance);

        vm.expectRevert(OllaCore.OllaCoreZeroAddress.selector);
        newVault.initialize(asset, IStAztec(address(0)), newStakingManager, newGovernance);

        vm.expectRevert(OllaCore.OllaCoreZeroAddress.selector);
        newVault.initialize(asset, newStAztec, IStakingManager(address(0)), newGovernance);

        vm.expectRevert(OllaCore.OllaCoreZeroAddress.selector);
        newVault.initialize(asset, newStAztec, newStakingManager, address(0));
    }

    function test_RevertWhen_UnauthorizedRedeem() external {
        _performDeposit(alice, 15 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreUnauthorized.selector, bob, alice));
        vm.prank(bob);
        vault.requestRedeem(5 * DECIMALS, bob, alice);
    }

    function test_RequestRedeemByOwner() external {
        _performDeposit(alice, 25 * DECIMALS);

        vm.prank(alice);
        uint256 assets = vault.requestRedeem(5 * DECIMALS, bob, alice);

        assertEq(assets, 5 * DECIMALS, "assets expected");
        assertEq(stAztec.balanceOf(alice), 20 * DECIMALS, "shares reduced");
    }

    function testFuzz_DepositMintsShares(uint96 assets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        uint256 shares = _performDeposit(alice, assets);

        assertEq(shares, assets, "shares minted at 1:1");
        assertEq(stAztec.balanceOf(alice), shares, "shares balance");
        assertEq(vault.totalAssets(), assets, "assets buffered");
    }

    function testFuzz_RequestRedeemBurnsShares(uint96 assets, uint96 redeemShares) external {
        assets = uint96(bound(assets, 1, type(uint96).max));
        redeemShares = uint96(bound(redeemShares, 1, assets));

        _performDeposit(alice, assets);

        vm.prank(alice);
        uint256 assetsOut = vault.requestRedeem(redeemShares, alice, alice);

        assertEq(assetsOut, redeemShares, "assets out");
        assertEq(stAztec.balanceOf(alice), assets - redeemShares, "shares remaining");

        vm.prank(bob);
        uint256 claimed = vault.claimPendingWithdraw(alice);

        assertEq(claimed, assetsOut, "claimed assets");
        assertEq(asset.balanceOf(alice), assetsOut, "assets received");
    }

    function testFuzz_RequestRedeemByOwner(uint96 assets, uint96 redeemShares) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        _performDeposit(alice, assets);

        redeemShares = uint96(bound(redeemShares, 1, assets));

        uint256 expectedAssets =
            uint256(redeemShares).mulDiv(vault.totalAssets(), stAztec.totalSupply(), Math.Rounding.Ceil);

        vm.prank(alice);
        uint256 assetsOut = vault.requestRedeem(redeemShares, bob, alice);

        assertEq(assetsOut, expectedAssets, "assets expected");
        assertEq(stAztec.balanceOf(alice), assets - redeemShares, "shares reduced");
    }

    function testFuzz_RequestRedeemUsesExchangeRate(uint96 assets, uint96 bonus, uint96 redeemShares) external {
        assets = uint96(bound(assets, 1, type(uint96).max));
        bonus = uint96(bound(bonus, 1, type(uint96).max));

        _performDeposit(alice, assets);
        vault.exposedIncreaseRewardsVaultBalance(bonus, EXPECTED_REASON_REWARD);

        redeemShares = uint96(bound(redeemShares, 1, assets));

        uint256 expectedAssets =
            uint256(redeemShares).mulDiv(vault.totalAssets(), stAztec.totalSupply(), Math.Rounding.Ceil);

        vm.prank(alice);
        uint256 assetsOut = vault.requestRedeem(redeemShares, alice, alice);

        assertEq(assetsOut, expectedAssets, "assets at exchange rate");
    }

    function testFuzz_RevertWhen_UnauthorizedRedeem(uint96 assets, uint96 redeemShares, address attacker) external {
        assets = uint96(bound(assets, 1, type(uint96).max));
        vm.assume(attacker != alice);
        vm.assume(attacker != address(0));

        _performDeposit(alice, assets);

        redeemShares = uint96(bound(redeemShares, 1, assets));

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreUnauthorized.selector, attacker, alice));
        vm.prank(attacker);
        vault.requestRedeem(redeemShares, attacker, alice);
    }

    function testFuzz_RevertWhen_ClaimInsufficientLiquidity(uint96 assets, uint96 redeemShares) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        _performDeposit(alice, assets);

        redeemShares = uint96(bound(redeemShares, 1, assets));

        vm.prank(alice);
        uint256 assetsOut = vault.requestRedeem(redeemShares, alice, alice);

        uint256 availableAssets = vault.bufferedAssets();

        vault.exposedDecreaseBuffered(availableAssets, EXPECTED_REASON_STAKE);
        vault.exposedIncreaseStakedPrincipal(availableAssets, EXPECTED_REASON_STAKE);

        vm.prank(address(vault));
        asset.transfer(bob, availableAssets);
        vault.exposedSyncBufferedWithBalance();

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreInsufficientLiquidity.selector, assetsOut, 0));
        vault.claimPendingWithdraw(alice);
    }
}
