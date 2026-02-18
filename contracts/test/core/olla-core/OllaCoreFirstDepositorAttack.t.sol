// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";

contract OllaCoreFirstDepositorAttackTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal attacker;
    address internal victim;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        attacker = makeAddr("attacker");
        victim = makeAddr("victim");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                     FIRST DEPOSITOR ATTACK TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The classic first-depositor attack: attacker deposits 1 wei, donates a large
    ///         amount directly to the vault, then waits for the victim to deposit. With the
    ///         virtual offset, the victim must still receive a fair share of the pool.
    function test_FirstDepositorAttack_VirtualOffsetPreventsShareDilution() external {
        uint256 donation = 10_000 * DECIMALS;
        uint256 victimDeposit = 9_999 * DECIMALS;

        // Step 1: Attacker deposits 1 wei to get initial shares.
        uint256 attackerShares = _performDeposit(attacker, 1);
        assertGt(attackerShares, 0, "attacker should receive shares for 1 wei deposit");

        // Step 2: Attacker donates a large amount directly to the vault.
        asset.mint(attacker, donation);
        vm.prank(attacker);
        asset.transfer(address(vault), donation);

        // Step 3: Sync buffered assets so the vault absorbs the donation.
        vault.exposedSyncBufferedWithBalance();

        // Step 4: Victim deposits.
        uint256 victimShares = _performDeposit(victim, victimDeposit);

        // Assert: victim receives shares (attack is prevented).
        assertGt(victimShares, 0, "victim must receive > 0 shares after donation attack");

        // Assert: victim's share of total value is fair. The victim deposited ~50% of
        // the post-deposit total assets, so they should hold roughly ~50% of shares.
        uint256 totalShares = stAztec.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        // Victim's proportional asset value via their share fraction.
        uint256 victimAssetValue = victimShares.mulDiv(totalAssets, totalShares, Math.Rounding.Floor);

        // The victim should not lose more than 1 wei to rounding.
        assertGe(victimAssetValue, victimDeposit - 1, "victim's asset value must be within 1 wei of their deposit");
    }

    /// @notice Verifies the attack is unprofitable: the attacker's extractable value after the
    ///         victim deposits is less than the attacker's total cost (1 wei + donation).
    function test_FirstDepositorAttack_AttackerLossesDominateProfit() external {
        uint256 donation = 10_000 * DECIMALS;
        uint256 victimDeposit = 9_999 * DECIMALS;

        // Attacker deposits 1 wei.
        uint256 attackerShares = _performDeposit(attacker, 1);

        // Attacker donates directly to the vault.
        asset.mint(attacker, donation);
        vm.prank(attacker);
        asset.transfer(address(vault), donation);
        vault.exposedSyncBufferedWithBalance();

        // Victim deposits.
        _performDeposit(victim, victimDeposit);

        // Calculate attacker's total cost.
        uint256 attackerCost = 1 + donation;

        // Calculate attacker's extractable value (share value).
        uint256 totalShares = stAztec.totalSupply();
        uint256 totalAssets = vault.totalAssets();
        uint256 attackerAssetValue = attackerShares.mulDiv(totalAssets, totalShares, Math.Rounding.Floor);

        // The attacker's extractable value must be less than their total cost.
        assertLt(attackerAssetValue, attackerCost, "attack must be unprofitable: extractable value < total cost");
    }

    /// @notice When the vault is empty, a first deposit should still mint shares approximately 1:1.
    ///         The +1 virtual offset is negligible at normal deposit scales.
    function test_FirstDeposit_StillWorksOneToOne() external {
        uint256 depositAmount = 100 * DECIMALS;

        uint256 shares = _performDeposit(victim, depositAmount);

        // With the virtual offset, the formula is: shares = assets * (0 + 1) / (0 + 1) = assets.
        // So at zero supply the 1:1 ratio is preserved exactly.
        assertEq(shares, depositAmount, "first deposit should mint shares 1:1 when vault is empty");
        assertEq(stAztec.balanceOf(victim), depositAmount, "shares balance should match deposit");
        assertEq(vault.totalAssets(), depositAmount, "total assets should equal deposited amount");
    }

    /// @notice Fuzz test: deposit a random amount and verify the roundtrip conversion is within
    ///         1 wei rounding tolerance. Deposits shares, then converts those shares back to
    ///         assets via the public convertToAssets view.
    function testFuzz_ConversionRoundtrip_NoSharesLostUnfairly(uint96 assets) external {
        assets = uint96(bound(assets, 1e18, type(uint96).max));

        uint256 shares = _performDeposit(victim, assets);

        // Convert shares back to assets using the public view function.
        uint256 recoveredAssets = vault.convertToAssets(shares);

        // The roundtrip should be within 1 wei of the original deposit.
        assertGe(recoveredAssets, uint256(assets) - 1, "recovered assets must be >= deposit - 1 wei");
        assertLe(recoveredAssets, uint256(assets), "recovered assets must not exceed deposit (no free value)");
    }

    /// @notice Fuzz test: vary the donation size and verify the victim always receives a fair
    ///         share, proving the virtual offset protects against arbitrary donation amounts.
    function testFuzz_FirstDepositorAttack_VaryingDonationSizes(uint96 donation) external {
        donation = uint96(bound(donation, 1e18, type(uint96).max));

        // Attacker deposits 1 wei.
        uint256 attackerShares = _performDeposit(attacker, 1);
        assertGt(attackerShares, 0, "attacker should receive shares");

        // Attacker donates directly to the vault.
        asset.mint(attacker, donation);
        vm.prank(attacker);
        asset.transfer(address(vault), donation);
        vault.exposedSyncBufferedWithBalance();

        // Victim deposits the same amount as the donation.
        uint256 victimShares = _performDeposit(victim, donation);

        // Victim must receive shares.
        assertGt(victimShares, 0, "victim must receive > 0 shares regardless of donation size");

        // Victim's share of total value should be fair.
        uint256 totalShares = stAztec.totalSupply();
        uint256 totalAssets = vault.totalAssets();
        uint256 victimAssetValue = victimShares.mulDiv(totalAssets, totalShares, Math.Rounding.Floor);

        // The victim deposited `donation` worth of assets into a pool that had `donation + 1`
        // total assets before the victim's deposit. After deposit, total is `2 * donation + 1`.
        // The victim's fair share is `donation / (2 * donation + 1)` of total assets.
        // With the virtual offset the rounding loss is at most 1 wei.
        assertGe(victimAssetValue, uint256(donation) - 1, "victim asset value must be within 1 wei of their deposit");
    }
}
