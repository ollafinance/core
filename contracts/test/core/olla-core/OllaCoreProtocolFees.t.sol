// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreProtocolFeesTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AccountingUpdated(
        uint256 totalAssets,
        uint256 exchangeRate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
    );
    event AttestersStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);
    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;
    uint256 internal constant BP_DIVISOR = 10_000;

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
    MockWithdrawalQueue internal withdrawalQueue;
    address internal operator;
    address internal alice;
    address internal providerRewardsRecipient;

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

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            governance,
            IRewardsAccumulator(address(rewardsAccumulator)),
            address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

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

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalculateProtocolFees_NonZeroAssets_MatchesConvertToShares() external {
        uint256 depositAmount = 50 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 grossRewards = 100 * DECIMALS;

        assertGt(stAztec.totalSupply(), 0, "supply nonzero");
        assertGt(core.totalAssets(), 0, "total assets nonzero");

        (uint256 feeAssets, uint256 treasuryShares, uint256 providerShares) =
            core.exposedCalculateProtocolFees(grossRewards);

        uint256 expectedFeeAssets = grossRewards * PROTOCOL_FEE_BP / BP_DIVISOR;
        uint256 expectedSharesTotal = core.convertToShares(expectedFeeAssets);

        assertEq(feeAssets, expectedFeeAssets, "fee assets");
        assertEq(treasuryShares + providerShares, expectedSharesTotal, "fee shares match convertToShares");
    }

    function test_CalculateProtocolFees_LargeAssetsTinyRewards_MatchesConvertToShares() external {
        uint256 depositAmount = 1e24;
        _performDeposit(alice, depositAmount);
        core.exposedApplyAccountingUpdates(1, 0, 0, 0, 0);

        uint256 grossRewards = 20;
        (uint256 feeAssets, uint256 treasuryShares, uint256 providerShares) =
            core.exposedCalculateProtocolFees(grossRewards);

        uint256 expectedFeeAssets = grossRewards * PROTOCOL_FEE_BP / BP_DIVISOR;
        uint256 expectedSharesTotal = core.convertToShares(expectedFeeAssets);
        uint256 supply = stAztec.totalSupply();
        uint256 totalAssets = core.totalAssets();

        assertEq(feeAssets, expectedFeeAssets, "fee assets");
        assertEq(supply, depositAmount, "supply from deposit");
        assertEq(totalAssets, depositAmount + 1, "total assets updated");
        assertEq(treasuryShares + providerShares, expectedSharesTotal, "fee shares match convertToShares");
        assertEq(
            expectedSharesTotal, expectedFeeAssets.mulDiv(supply, totalAssets, Math.Rounding.Floor), "shares floor"
        );
        assertEq(expectedSharesTotal, 0, "tiny fee rounds down");
    }

    function test_UpdateAccounting_PaysProtocolFeesAndMintsSplitShares() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 rewards = 20 * DECIMALS;

        uint256 sharesMinted = _performDeposit(alice, depositAmount);
        assertEq(sharesMinted, depositAmount, "deposit mints 1:1 at zero supply");

        stakingManager.setClaimableRewards(rewards);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        uint256 expectedTotalAssets = depositAmount + rewards;
        uint256 grossRewards = rewards;
        uint256 protocolFeeAssets = grossRewards * PROTOCOL_FEE_BP / BP_DIVISOR;

        uint256 rateBeforeRewards = expectedTotalAssets.mulDiv(DECIMALS, oldSupply, Math.Rounding.Floor);
        uint256 protocolSharesTotal = protocolFeeAssets.mulDiv(DECIMALS, rateBeforeRewards, Math.Rounding.Floor);
        uint256 treasuryShares = protocolSharesTotal * TREASURY_FEE_SPLIT_BP / BP_DIVISOR;
        uint256 providerShares = protocolSharesTotal - treasuryShares;

        uint256 expectedRateAfter =
            expectedTotalAssets.mulDiv(DECIMALS, oldSupply + protocolSharesTotal, Math.Rounding.Floor);
        uint256 expectedTimestamp = block.timestamp;

        vm.expectEmit(true, true, true, true, address(core));
        emit OllaProtocolFeesPaid(protocolFeeAssets, treasuryShares, providerShares);
        vm.expectEmit(true, true, true, true, address(core));
        emit AttestersStateRead(rewards, 0, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(core));
        emit AccountingUpdated(
            expectedTotalAssets,
            expectedRateAfter,
            grossRewards,
            int256(depositAmount),
            protocolFeeAssets,
            treasuryShares,
            providerShares,
            expectedTimestamp
        );

        vm.prank(operator);
        core.updateAccounting();

        assertEq(stAztec.totalSupply(), oldSupply + protocolSharesTotal, "protocol fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares + treasuryShares, "treasury shares minted");
        assertEq(
            stAztec.balanceOf(providerRewardsRecipient), oldProviderShares + providerShares, "provider shares minted"
        );
    }

    function test_UpdateAccounting_ProtocolFeeSplitRoundsDownTreasuryAndKeepsRemainder() external {
        uint256 depositAmount = 100 * DECIMALS;

        _performDeposit(alice, depositAmount);

        // Pick rewards that are very likely to produce a fractional share result,
        // so floor rounding differs from ceil and leaves a remainder to the provider split.
        uint256 rewards = 1 * DECIMALS + 1;
        stakingManager.setClaimableRewards(rewards);

        uint256 oldSupply = stAztec.totalSupply();

        uint256 expectedTotalAssets = depositAmount + rewards;
        uint256 protocolFeeAssets = rewards * PROTOCOL_FEE_BP / BP_DIVISOR;
        uint256 rateBeforeRewards = expectedTotalAssets.mulDiv(DECIMALS, oldSupply, Math.Rounding.Floor);
        uint256 protocolSharesTotal = protocolFeeAssets.mulDiv(DECIMALS, rateBeforeRewards, Math.Rounding.Floor);
        uint256 protocolSharesCeil = protocolFeeAssets.mulDiv(DECIMALS, rateBeforeRewards, Math.Rounding.Ceil);

        uint256 treasuryShares = protocolSharesTotal * TREASURY_FEE_SPLIT_BP / BP_DIVISOR;
        uint256 providerShares = protocolSharesTotal - treasuryShares;

        assertLt(protocolSharesTotal, protocolSharesCeil, "floor rounding applied");
        // Invariant: split adds up exactly, and provider keeps any remainder from floor split.
        assertEq(treasuryShares + providerShares, protocolSharesTotal, "split sums to total");
        assertLe(treasuryShares, providerShares + 1, "treasury floor split at 50/50");

        vm.prank(operator);
        core.updateAccounting();

        assertEq(stAztec.balanceOf(governance), treasuryShares, "treasury minted (from zero)");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), providerShares, "provider minted (from zero)");
    }

    function test_UpdateAccounting_NetFlowsNegative_NoPhantomFees() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.updateAccounting();

        uint256 sharesToRedeem = 40 * DECIMALS;
        uint256 rate = core.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice, alice);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        assertEq(reportAfter.netFlows, -int256(assetsExpected), "net flows negative");
        // No actual rewards accrued -- pending withdrawal assets are excluded from totalAssets
        // so no phantom rewards are computed and no protocol fees are minted.
        assertEq(reportAfter.grossRewards, 0, "no phantom rewards from withdrawal requests");
        assertEq(stAztec.totalSupply(), oldSupply, "no fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares, "treasury shares unchanged");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), oldProviderShares, "provider shares unchanged");
    }

    function test_UpdateAccounting_GrossRewardsClamp_NoFeeMinting() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.updateAccounting();

        uint256 extraDeposit = 10 * DECIMALS;
        _performDeposit(alice, extraDeposit);
        stakingManager.setSlashingDelta(30 * DECIMALS);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        assertEq(reportAfter.grossRewards, 0, "gross rewards clamped to zero");
        assertEq(reportAfter.netFlows, int256(extraDeposit), "net flows positive");
        assertEq(stAztec.totalSupply(), oldSupply, "no fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares, "no treasury shares minted");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), oldProviderShares, "no provider shares minted");
    }

    function test_UpdateAccounting_GrossRewardsZero_TotalAssetsZero_NoFeeMinting() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        core.updateAccounting();

        stakingManager.setSlashingDelta(depositAmount);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        core.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = core.latestReport();
        assertEq(reportAfter.grossRewards, 0, "gross rewards zero");
        assertEq(reportAfter.totalAssets, 0, "report total assets zero");
        assertEq(reportAfter.exchangeRate, 0, "exchange rate zero");
        assertEq(core.totalAssets(), 0, "total assets zeroed");
        assertEq(stAztec.totalSupply(), oldSupply, "no fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares, "no treasury shares minted");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), oldProviderShares, "no provider shares minted");
        assertGt(stAztec.totalSupply(), 0, "supply remains positive");
    }

    /// @notice Reproduces rounding error from invariant test failure.
    /// The contract's convertToAssets uses two mulDiv operations (via exchangeRate),
    /// while the spec expects a single mulDiv: shares * totalAssets / totalSupply.
    /// This causes a 1 wei difference at large values.
    function test_ConvertToAssets_RoundingError_ReproducesInvariantFailure() external {
        // Step 1: Deposit first to create shares (supply > 0)
        // With virtual offset, depositing after inflating totalAssets would yield 0 shares
        // since shares = assets * (0 + 1) / (largeStaked + 1) = 0 (floor).
        uint256 depositAmount = 3;
        _performDeposit(alice, depositAmount);

        // Step 2: Set a large totalStaked value (inflates totalAssets)
        uint256 largeStaked = 10135855071863320976892102731;
        stakingManager.setTotalStaked(largeStaked);

        // Step 3: Update accounting to apply the staked principal
        vm.prank(operator);
        core.updateAccounting();

        // Step 4: Now check the invariant: convertToAssets with virtual offset
        uint256 supply = stAztec.totalSupply();
        uint256 total = core.totalAssets();

        uint256 shares = supply; // Use total supply as test shares

        // Contract's implementation (uses virtual offset)
        uint256 contractResult = core.convertToAssets(shares);

        // Expected result with virtual offset: shares * (total + 1) / (supply + 1)
        uint256 expectedResult = shares.mulDiv(total + 1, supply + 1, Math.Rounding.Floor);

        assertEq(contractResult, expectedResult, "convertToAssets matches spec");
    }

    /*//////////////////////////////////////////////////////////////
                  FUZZ: PROTOCOL FEE CALCULATION
    //////////////////////////////////////////////////////////////*/

    function testFuzz_CalculateProtocolFees(uint96 grossRewards, uint16 feeBP, uint16 splitBP) external {
        feeBP = uint16(bound(feeBP, 0, 5_000));
        splitBP = uint16(bound(splitBP, 1_000, 9_000));
        grossRewards = uint96(bound(grossRewards, 0, type(uint96).max));

        // Deposit to establish nonzero supply and totalAssets
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Set fee and split parameters via governance
        vm.startPrank(governance);
        core.setProtocolFeeBP(feeBP);
        core.setTreasuryFeeSplitBP(splitBP);
        vm.stopPrank();

        (uint256 feeAssets, uint256 treasuryShares, uint256 providerShares) =
            core.exposedCalculateProtocolFees(grossRewards);

        uint256 expectedFeeAssets = uint256(grossRewards) * feeBP / BP_DIVISOR;
        assertEq(feeAssets, expectedFeeAssets, "feeAssets == grossRewards * feeBP / 10000");

        // Shares split sums to total
        uint256 totalShares = core.convertToShares(expectedFeeAssets);
        assertEq(treasuryShares + providerShares, totalShares, "treasury + provider == total shares");
    }
}
