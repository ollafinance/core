// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

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
    bytes32 internal constant REASON_DEPOSIT = "DEPOSIT";
    bytes32 internal constant REASON_CLAIM = "CLAIM";
    bytes32 internal constant REASON_STAKE = "STAKE";
    bytes32 internal constant REASON_SLASH = "SLASH";
    bytes32 internal constant REASON_REWARD = "REWARD";

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    address internal alice;
    address internal bob;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness implementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCoreHarness(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        vault.initialize(asset, stAztec, stakingManager);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function test_DepositMintsAtExchangeRate() external {
        uint256 firstShares = _deposit(alice, 100 * DECIMALS);
        assertEq(firstShares, 100 * DECIMALS, "initial shares");

        vault.exposedIncreaseRewardsVaultBalance(50 * DECIMALS, REASON_REWARD);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSharesBefore = stAztec.totalSupply();

        uint256 expectedShares = (50 * DECIMALS).mulDiv(totalSharesBefore, totalAssetsBefore, Math.Rounding.Floor);
        uint256 secondShares = _deposit(bob, 50 * DECIMALS);

        assertEq(secondShares, expectedShares, "shares at exchange rate");
    }

    function test_DepositsAreInstant() external {
        uint256 shares = _deposit(alice, 10 * DECIMALS);

        assertEq(stAztec.balanceOf(alice), shares, "shares minted");
        assertEq(vault.totalAssets(), 10 * DECIMALS, "assets buffered");
    }

    function test_BucketGettersReflectState() external {
        uint256 assets = 10 * DECIMALS;
        uint256 staked = 6 * DECIMALS;
        uint256 rewardsVault = 4 * DECIMALS;
        uint256 rewardsDelta = 2 * DECIMALS;
        uint256 slashingDelta = 1 * DECIMALS;

        _deposit(alice, assets);
        vault.exposedIncreaseStakedPrincipal(staked, REASON_STAKE);
        vault.exposedIncreaseRewardsVaultBalance(rewardsVault, REASON_REWARD);
        vault.exposedSetRewardsDelta(rewardsDelta, REASON_REWARD);
        vault.exposedSetSlashingDelta(slashingDelta, REASON_SLASH);

        assertEq(vault.bufferedAssets(), assets, "buffered assets");
        assertEq(vault.stakedPrincipal(), staked, "staked principal");
        assertEq(vault.rewardsVaultBalance(), rewardsVault, "rewards vault balance");
        assertEq(vault.rewardsDelta(), rewardsDelta, "rewards delta");
        assertEq(vault.slashingDelta(), slashingDelta, "slashing delta");
        assertEq(vault.totalAssets(), assets + staked + rewardsVault + rewardsDelta - slashingDelta, "total assets sum");
    }

    function test_BucketHelpersEmitEvents() external {
        uint256 amount = 5 * DECIMALS;

        vm.expectEmit(true, true, true, true, address(vault));
        emit BucketUpdated(0, 0, amount, REASON_DEPOSIT);
        vault.exposedIncreaseBuffered(amount, REASON_DEPOSIT);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BucketUpdated(0, amount, 0, REASON_CLAIM);
        vault.exposedDecreaseBuffered(amount, REASON_CLAIM);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BucketUpdated(1, 0, amount, REASON_STAKE);
        vault.exposedIncreaseStakedPrincipal(amount, REASON_STAKE);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BucketUpdated(2, 0, amount, REASON_REWARD);
        vault.exposedIncreaseRewardsVaultBalance(amount, REASON_REWARD);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BucketUpdated(3, 0, amount, REASON_REWARD);
        vault.exposedSetRewardsDelta(amount, REASON_REWARD);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BucketUpdated(4, 0, amount, REASON_SLASH);
        vault.exposedSetSlashingDelta(amount, REASON_SLASH);

        assertEq(vault.bufferedAssets(), 0, "buffered cleared");
        assertEq(vault.stakedPrincipal(), amount, "staked credited");
        assertEq(vault.rewardsVaultBalance(), amount, "rewards vault credited");
        assertEq(vault.rewardsDelta(), amount, "rewards delta set");
        assertEq(vault.slashingDelta(), amount, "slashing delta set");
    }

    function test_SyncBufferedWithBalanceAfterDepositAndClaim() external {
        uint256 assets = 10 * DECIMALS;

        _deposit(alice, assets);
        vault.exposedSyncBufferedWithBalance();

        vm.prank(alice);
        vault.requestRedeem(5 * DECIMALS, alice, alice);

        vm.prank(bob);
        vault.claimPendingWithdraw(alice);
        vault.exposedSyncBufferedWithBalance();
    }

    function test_StakeDoesNotChangeBuckets() external {
        uint256 assets = 12 * DECIMALS;

        _deposit(alice, assets);

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

        uint256 positiveTotal = uint256(buffered) + staked + rewardsVault + rewardsDelta;
        uint256 slashingDelta = bound(uint256(slashingDeltaSeed), 0, positiveTotal);

        asset.mint(address(vault), buffered);
        vault.exposedIncreaseBuffered(buffered, REASON_DEPOSIT);
        vault.exposedIncreaseStakedPrincipal(staked, REASON_STAKE);
        vault.exposedIncreaseRewardsVaultBalance(rewardsVault, REASON_REWARD);
        vault.exposedSetRewardsDelta(rewardsDelta, REASON_REWARD);
        vault.exposedSetSlashingDelta(slashingDelta, REASON_SLASH);

        assertEq(vault.totalAssets(), positiveTotal - slashingDelta, "total assets sum");
    }

    function test_RevertWhen_BufferedBalanceMismatch() external {
        uint256 assets = 10 * DECIMALS;
        uint256 bonus = 2 * DECIMALS;

        _deposit(alice, assets);
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
        _deposit(alice, 25 * DECIMALS);

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
        _deposit(alice, 20 * DECIMALS);

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
        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        OllaCore newVault = OllaCore(address(proxy));
        StAztec newStAztec = new StAztec(address(newVault));
        MockStakingManager newStakingManager = new MockStakingManager();

        vm.expectRevert(OllaCore.OllaCoreZeroAddress.selector);
        newVault.initialize(IERC20(address(0)), newStAztec, newStakingManager);

        vm.expectRevert(OllaCore.OllaCoreZeroAddress.selector);
        newVault.initialize(asset, IStAztec(address(0)), newStakingManager);

        vm.expectRevert(OllaCore.OllaCoreZeroAddress.selector);
        newVault.initialize(asset, newStAztec, IStakingManager(address(0)));
    }

    function test_RevertWhen_UnauthorizedRedeem() external {
        _deposit(alice, 15 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreUnauthorized.selector, bob, alice));
        vm.prank(bob);
        vault.requestRedeem(5 * DECIMALS, bob, alice);
    }

    function test_RequestRedeemByOwner() external {
        _deposit(alice, 25 * DECIMALS);

        vm.prank(alice);
        uint256 assets = vault.requestRedeem(5 * DECIMALS, bob, alice);

        assertEq(assets, 5 * DECIMALS, "assets expected");
        assertEq(stAztec.balanceOf(alice), 20 * DECIMALS, "shares reduced");
    }

    function testFuzz_DepositMintsShares(uint96 assets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        uint256 shares = _deposit(alice, assets);

        assertEq(shares, assets, "shares minted at 1:1");
        assertEq(stAztec.balanceOf(alice), shares, "shares balance");
        assertEq(vault.totalAssets(), assets, "assets buffered");
    }

    function testFuzz_RequestRedeemBurnsShares(uint96 assets, uint96 redeemShares) external {
        assets = uint96(bound(assets, 1, type(uint96).max));
        redeemShares = uint96(bound(redeemShares, 1, assets));

        _deposit(alice, assets);

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

        _deposit(alice, assets);

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

        _deposit(alice, assets);
        vault.exposedIncreaseRewardsVaultBalance(bonus, REASON_REWARD);

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

        _deposit(alice, assets);

        redeemShares = uint96(bound(redeemShares, 1, assets));

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreUnauthorized.selector, attacker, alice));
        vm.prank(attacker);
        vault.requestRedeem(redeemShares, attacker, alice);
    }

    function testFuzz_RevertWhen_ClaimInsufficientLiquidity(uint96 assets, uint96 redeemShares) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        _deposit(alice, assets);

        redeemShares = uint96(bound(redeemShares, 1, assets));

        vm.prank(alice);
        uint256 assetsOut = vault.requestRedeem(redeemShares, alice, alice);

        uint256 availableAssets = vault.bufferedAssets();

        vault.exposedDecreaseBuffered(availableAssets, REASON_STAKE);
        vault.exposedIncreaseStakedPrincipal(availableAssets, REASON_STAKE);

        vm.prank(address(vault));
        asset.transfer(bob, availableAssets);
        vault.exposedSyncBufferedWithBalance();

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreInsufficientLiquidity.selector, assetsOut, 0));
        vault.claimPendingWithdraw(alice);
    }
}
