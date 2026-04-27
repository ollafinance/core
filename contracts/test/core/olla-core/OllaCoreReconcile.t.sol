// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";

contract ReconcileSafetyModule is ISafetyModule {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ReconcileSafetyModule__TotalBelowActual(uint256 total, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                                 IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable CORE_ADDRESS;
    address public immutable VAULT_ADDRESS;
    IERC20 public immutable ASSET;

    /*//////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////*/

    bool internal _paused;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address coreAddress, address vaultAddress, IERC20 asset) {
        CORE_ADDRESS = coreAddress;
        VAULT_ADDRESS = vaultAddress;
        ASSET = asset;
    }

    /*//////////////////////////////////////////////////////////////
                               CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pause() external override {
        _paused = true;
    }

    function unpause() external override {
        _paused = false;
    }

    function isPaused() external view override returns (bool pausedState) {
        return _paused;
    }

    function CORE() external view override returns (address) {
        return CORE_ADDRESS;
    }

    function VAULT() external view override returns (address) {
        return VAULT_ADDRESS;
    }

    function checkRateDrop(uint256 oldRate, uint256 nextRate) external pure override {
        _noop(oldRate + nextRate);
    }

    function checkQueueRatio(uint256 queued, uint256 total) external view override {
        uint256 actual = ASSET.balanceOf(CORE_ADDRESS);
        if (total < actual) {
            revert ReconcileSafetyModule__TotalBelowActual(total, actual);
        }
        _noop(queued + total);
    }

    function checkAccountingLiveness(uint256) external pure override {
        _noop(0);
    }

    /*//////////////////////////////////////////////////////////////
                        PROVIDER AND ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setDepositCap(uint256 cap) external pure override {
        _noop(cap);
    }

    function setWithdrawalMinimum(uint256 minimumShares) external pure override {
        _noop(minimumShares);
    }

    function setMinRateDropBps(uint256 minRateDropBps) external pure override {
        _noop(minRateDropBps);
    }

    function setMaxQueueRatioBps(uint256 maxQueueRatioBps) external pure override {
        _noop(maxQueueRatioBps);
    }

    function setMaxAccountingDelay(uint256 maxAccountingDelay) external pure override {
        _noop(maxAccountingDelay);
    }

    function setLatestAccountingTimestamp(uint256 latestAccountingTimestamp) external pure override {
        _noop(latestAccountingTimestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function checkDepositAllowed(uint256 deposit, uint256 total) external pure override returns (bool allowed) {
        _noop(deposit + total);
        return true;
    }

    function checkWithdrawalMinimum(uint256 shares) external pure override {
        _noop(shares);
    }

    function depositCap() external pure override returns (uint256) {
        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _noop(uint256 value) internal pure {
        unchecked {
            uint256 temp = value;
            ++temp;
            --temp;
            if (temp == type(uint256).max) {
                temp = 0;
            }
        }
    }
}

contract OllaCoreReconcileTest is Test {
    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed recipient, uint256 assets, uint256 shares);
    event WithdrawalFinalized(uint256 available, uint256 used);
    event BufferedAssetsReconciled(uint256 delta, uint256 newBufferedAssets, address indexed recipient);

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
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    MockWithdrawalQueue internal withdrawalQueue;
    address internal governance;
    address internal operator;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();
        operator = makeAddr("operator");

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
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
                                RECONCILIATION
    //////////////////////////////////////////////////////////////*/

    function test_ReconcileBufferedAssets_ForcedTransfer_AllowsDepositAndFinalize() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 bonus = 3 * DECIMALS;
        asset.mint(bob, bonus);
        vm.prank(bob);
        asset.transfer(address(vault), bonus);

        uint256 bufferedBefore = vault.bufferedAssets();
        assertEq(bufferedBefore, depositAmount, "buffered assets before reconcile");
        assertEq(asset.balanceOf(address(vault)), depositAmount + bonus, "actual balance includes forced transfer");

        IOllaCore.FlowCounters memory flowsBefore = core.flowCounters();

        vm.expectEmit(true, true, true, true, address(vault));
        emit BufferedAssetsReconciled(bonus, depositAmount + bonus, address(vault));

        vm.prank(governance);
        uint256 delta = vault.reconcileBufferedAssets();

        assertEq(delta, bonus, "reconcile delta");
        uint256 bufferedAfter = vault.bufferedAssets();
        assertEq(bufferedAfter, depositAmount + bonus, "buffered assets reconciled");

        IOllaCore.FlowCounters memory flowsAfter = core.flowCounters();
        assertEq(flowsAfter.cumulativeDeposits, flowsBefore.cumulativeDeposits, "cumulative deposits unchanged");
        assertEq(
            flowsAfter.cumulativeWithdrawals, flowsBefore.cumulativeWithdrawals, "cumulative withdrawals unchanged"
        );

        uint256 secondDeposit = 4 * DECIMALS;
        asset.mint(bob, secondDeposit);
        vm.prank(bob);
        asset.approve(address(vault), secondDeposit);

        uint256 expectedShares = vault.previewDeposit(secondDeposit);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(bob, bob, secondDeposit, expectedShares);

        vm.prank(bob);
        uint256 mintedShares = vault.deposit(secondDeposit, bob, 0);

        assertEq(mintedShares, expectedShares, "deposit shares after reconcile");
        assertEq(stAztec.balanceOf(bob), expectedShares, "shares minted to bob");
    }

    function test_Deposit_ReconcilesDonationBeforeShareCalculation() external {
        uint256 initialDeposit = 10 * DECIMALS;
        _performDeposit(alice, initialDeposit);

        uint256 bonus = 2 * DECIMALS;
        asset.mint(bob, bonus);
        vm.prank(bob);
        asset.transfer(address(vault), bonus);

        uint256 secondDeposit = 4 * DECIMALS;
        asset.mint(bob, secondDeposit);
        vm.prank(bob);
        asset.approve(address(vault), secondDeposit);

        uint256 supplyBefore = stAztec.totalSupply();
        uint256 totalAssetsWithDonation = initialDeposit + bonus;
        uint256 expectedShares = secondDeposit * (supplyBefore + 1e3) / (totalAssetsWithDonation + 1e3);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BufferedAssetsReconciled(bonus, totalAssetsWithDonation, address(vault));

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(bob, bob, secondDeposit, expectedShares);

        vm.prank(bob);
        uint256 mintedShares = vault.deposit(secondDeposit, bob, 0);

        assertEq(mintedShares, expectedShares, "shares priced after reconciliation");
    }

    /*//////////////////////////////////////////////////////////////
                DONATION ATTACK MITIGATION (C1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents donation attack mitigation via virtual offset (+1e3).
    /// When an attacker deposits 1 wei (getting 1 share) and donates 10_000e18 directly,
    /// a victim depositing 9_999e18 still receives shares thanks to the virtual offset
    /// in _convertToShares: assets * (totalSupply + 1e3) / (totalAssets + 1e3).
    function test_ReconcileBufferedAssets_DonationAttack_FirstDepositor() external {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        // Step 1: Attacker deposits 1 wei -- first depositor
        uint256 attackerShares = _performDeposit(attacker, 1);
        assertEq(attackerShares, 1, "attacker should receive 1 share for 1 wei deposit");
        assertEq(stAztec.totalSupply(), 1, "total supply should be 1 after attacker deposit");

        // Step 2: Attacker sends 10_000e18 directly to vault (donation)
        uint256 donationAmount = 10_000e18;
        asset.mint(attacker, donationAmount);
        vm.prank(attacker);
        asset.transfer(address(vault), donationAmount);

        // Buffered assets have not been reconciled yet
        uint256 bufferedPreVictim = vault.bufferedAssets();
        assertEq(bufferedPreVictim, 1, "buffered should still be 1 before reconcile");

        // Step 3: Victim deposits 9_999e18
        // The deposit flow calls _syncBufferedWithBalance first, which reconciles the donation.
        // After reconciliation: totalAssets = 1 + 10_000e18, totalSupply = 1
        uint256 victimDeposit = 9_999e18;
        uint256 victimShares = _performDeposit(victim, victimDeposit);

        // Virtual offset protects the victim: they get shares > 0
        assertGt(victimShares, 0, "victim should receive shares > 0 due to virtual offset protection");

        // Compute expected shares via the formula: assets * (supply + 1e3) / (totalAssets + 1e3)
        uint256 supplyAtConversion = 1;
        uint256 totalAssetsAtConversion = 1 + donationAmount;
        uint256 expectedVictimShares = (victimDeposit * (supplyAtConversion + 1e3)) / (totalAssetsAtConversion + 1e3);
        assertEq(victimShares, expectedVictimShares, "victim shares should match virtual offset formula");

        // Document: attacker still holds disproportionate share value, but victim is not zeroed out
        uint256 totalSharesAfter = stAztec.totalSupply();
        assertEq(totalSharesAfter, attackerShares + victimShares, "total supply should equal attacker + victim shares");
    }
}
