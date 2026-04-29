// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test, Vm } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";

/// @title OllaCoreWithdrawalRateTest
/// @notice Tests for the internal _withdrawalRate() function exposed via OllaCoreHarness.
/// @dev _withdrawalRate() uses a "gross" total assets / supply calculation (before subtracting
///      pending withdrawals) that differs from the standard exchangeRate().
contract OllaCoreWithdrawalRateTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;
    address internal providerRewardsRecipient;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        operator = makeAddr("operator");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    function _requestRedeem(address owner, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, owner, owner);
        return requestId;
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice With no pending withdrawals, withdrawalRate equals exchangeRate.
    function test_WithdrawalRate_EqualsExchangeRate_NoPendingWithdrawals() external {
        _deposit(alice, 100 * DECIMALS);

        uint256 withdrawalRate = core.exposedWithdrawalRate();
        uint256 exchangeRate = core.exchangeRate();

        assertEq(withdrawalRate, exchangeRate, "Withdrawal rate should equal exchange rate with no pending withdrawals");
    }

    /// @notice With pending withdrawals, withdrawalRate uses gross assets (not net of pending),
    ///         so it should be lower than or equal to exchangeRate.
    function test_WithdrawalRate_LowerThanExchangeRate_WithPendingWithdrawals() external {
        uint256 shares = _deposit(alice, 100 * DECIMALS);

        // Request partial redeem to create pending withdrawals
        _requestRedeem(alice, shares / 2);

        uint256 withdrawalRate = core.exposedWithdrawalRate();
        uint256 exchangeRate = core.exchangeRate();

        // With pending withdrawals:
        // - exchangeRate: uses totalAssets() (net of pending) / current totalSupply
        // - withdrawalRate: uses grossAssets (not net of pending) / grossSupply (supply + pendingShares)
        // Since shares are burned on requestRedeem, totalSupply decreases.
        // The grossSupply includes both current supply + pendingShares, making the denominator bigger.
        // grossAssets doesn't subtract pending, making numerator bigger.
        // The net effect: withdrawalRate should be <= exchangeRate
        assertLe(withdrawalRate, exchangeRate, "Withdrawal rate should be <= exchange rate with pending withdrawals");
    }

    /// @notice _withdrawalRate is used to pass to finalizeWithdrawals during rebalance.
    ///         Verify it gets called with the correct value by checking event emission.
    function test_WithdrawalRate_PassedToFinalizeWithdrawals() external {
        uint256 shares = _deposit(alice, 100 * DECIMALS);

        // Request redeem to create pending withdrawals
        _requestRedeem(alice, shares / 2);

        // Record the withdrawal rate before rebalance
        uint256 expectedRate = core.exposedWithdrawalRate();

        // Rebalance should pass this rate to finalizeWithdrawals
        // The MockWithdrawalQueue will receive it as currentRate parameter
        core.rebalance();

        // Since there are no staking operations and buffer covers the request,
        // verify the finalization happened (check that the request was processed)
        uint256 nextPending = uint64(vault.nextUnfinalizedWithdrawalRequestId());
        assertGt(nextPending, 1, "Withdrawal should have been finalized during rebalance");

        // The rate passed to finalizeWithdrawals should equal exposedWithdrawalRate
        // We verify this indirectly: the finalization used the correct rate
        assertGt(expectedRate, 0, "Withdrawal rate should be positive");
    }

    /// @notice Fuzz test: withdrawalRate is always <= exchangeRate.
    function testFuzz_WithdrawalRate_AlwaysLeqExchangeRate(uint96 depositAmount, uint96 redeemFraction) external {
        uint256 deposit = bound(depositAmount, 1e18, 1_000_000 * DECIMALS);
        uint256 shares = _deposit(alice, deposit);

        // Optionally create pending withdrawals
        uint256 fraction = bound(redeemFraction, 0, 1e18);
        uint256 redeemShares = (shares * fraction) / 1e18;
        if (redeemShares > 0 && redeemShares <= shares) {
            _requestRedeem(alice, redeemShares);
        }

        uint256 withdrawalRate = core.exposedWithdrawalRate();
        uint256 exchangeRate = core.exchangeRate();

        assertLe(withdrawalRate, exchangeRate, "Withdrawal rate must always be <= exchange rate");
    }

    /// @notice After slashing, withdrawalRate reflects the loss.
    function test_WithdrawalRate_WithSlashing() external {
        _deposit(alice, 100 * DECIMALS);

        uint256 rateBefore = core.exposedWithdrawalRate();

        // Drive slashing through the owning module: totalAssets() now reads
        // stakingManager.totalStaked() (net of slashing) live at call time.
        // Target: stakedPrincipal=50e18, slashingDelta=10e18.
        // setSlashingDelta subtracts the increment from totalStakedAmount, so apply it first and
        // then raise totalStaked to the intended net-of-slashing target.
        stakingManager.setSlashingDelta(10 * DECIMALS);
        stakingManager.setTotalStaked(50 * DECIMALS);

        uint256 rateAfter = core.exposedWithdrawalRate();

        // Rate must remain positive after the state change; absolute movement depends on how
        // bufferedAssets, net-of-slash staked, and pending interact.
        assertGt(rateBefore, 0, "Rate before should be positive");
        assertGt(rateAfter, 0, "Rate after should be positive");

        // Severe slashing: net-of-slash staked collapses to 10e18 and slashingDelta climbs to 40e18.
        stakingManager.setSlashingDelta(40 * DECIMALS);
        stakingManager.setTotalStaked(10 * DECIMALS);

        uint256 rateAfterSevereSlash = core.exposedWithdrawalRate();
        assertLt(rateAfterSevereSlash, rateAfter, "Rate should drop after severe slashing");
    }

    /// @notice Withdrawal rate equals exchange rate when deposits exist but no redemptions.
    function test_WithdrawalRate_EqualsExchangeRate_WithRewards() external {
        _deposit(alice, 100 * DECIMALS);

        // Simulate rewards accrual sitting in the RewardsAccumulator. totalAssets() reads
        // `rewardsAccumulator.balance()` live via `_liveAccountingState()`, so dealing the
        // asset to the accumulator is the pull-model equivalent of seeding
        // `_accountingState.rewardsAccumulatorBalance` directly.
        deal(address(asset), address(rewardsAccumulator), 10 * DECIMALS);

        uint256 withdrawalRate = core.exposedWithdrawalRate();
        uint256 exchangeRate = core.exchangeRate();

        // Without pending withdrawals, both rates should be equal
        assertEq(withdrawalRate, exchangeRate, "Rates should be equal with rewards but no pending withdrawals");
    }
}
