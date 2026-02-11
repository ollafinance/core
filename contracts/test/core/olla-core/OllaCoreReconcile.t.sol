// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
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
    IERC20 public immutable ASSET;

    /*//////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////*/

    bool internal _paused;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address coreAddress, IERC20 asset) {
        CORE_ADDRESS = coreAddress;
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

    function core() external view override returns (address) {
        return CORE_ADDRESS;
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

    function checkAccountingLiveness() external pure override {
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
    OllaCore internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsVault internal rewardsVault;
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
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();
        operator = makeAddr("operator");

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();
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
                                RECONCILIATION
    //////////////////////////////////////////////////////////////*/

    function test_ReconcileBufferedAssets_ForcedTransfer_AllowsDepositAndFinalize() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 bonus = 3 * DECIMALS;
        asset.mint(bob, bonus);
        vm.prank(bob);
        asset.transfer(address(vault), bonus);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        assertEq(accountingBefore.bufferedAssets, depositAmount, "buffered assets before reconcile");
        assertEq(asset.balanceOf(address(vault)), depositAmount + bonus, "actual balance includes forced transfer");

        IOllaCore.FlowCounters memory flowsBefore = vault.flowCounters();

        vm.expectEmit(true, true, true, true, address(vault));
        emit BufferedAssetsReconciled(bonus, depositAmount + bonus, address(vault));

        vm.prank(operator);
        uint256 delta = vault.reconcileBufferedAssets();

        assertEq(delta, bonus, "reconcile delta");
        IOllaCore.AccountingState memory accountingAfter = vault.accountingState();
        assertEq(accountingAfter.bufferedAssets, depositAmount + bonus, "buffered assets reconciled");

        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
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
        uint256 mintedShares = vault.deposit(secondDeposit, bob);

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
        uint256 expectedShares = secondDeposit * supplyBefore / totalAssetsWithDonation;

        vm.expectEmit(true, true, true, true, address(vault));
        emit BufferedAssetsReconciled(bonus, totalAssetsWithDonation, address(vault));

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(bob, bob, secondDeposit, expectedShares);

        vm.prank(bob);
        uint256 mintedShares = vault.deposit(secondDeposit, bob);

        assertEq(mintedShares, expectedShares, "shares priced after reconciliation");
    }
}
