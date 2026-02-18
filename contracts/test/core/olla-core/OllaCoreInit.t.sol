// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";

contract OllaCoreInitTest is Test {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event Paused();
    event Unpaused();

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
    address internal alice;
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

        alice = makeAddr("alice");
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_InitializeSetsCoreAddresses() external view {
        assertEq(vault.asset(), address(asset), "asset set");
        assertEq(vault.stAztec(), address(stAztec), "stAztec set");
        assertEq(vault.stakingManager(), address(stakingManager), "staking manager set");
        assertEq(vault.governance(), governance, "governance set");
        assertEq(vault.withdrawalQueue(), address(withdrawalQueue), "withdrawal queue set");
        assertEq(vault.rewardsVault(), address(rewardsVault), "rewards vault set");
        assertEq(vault.safetyModule(), address(safetyModule), "safety module set");
        assertEq(vault.targetBufferedAssets(), 0, "target buffered assets init");
        IOllaCore.LatestReport memory report = vault.latestReport();
        assertEq(report.exchangeRate, 1e18, "exchange rate init");
        assertEq(report.totalAssets, 0, "lastTotalAssets init");
    }

    function test_RevertWhen_Reinitialize() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
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
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_GuardianCanPauseAndUnpause() external {
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paused();
        vm.prank(governance);
        vault.pause();

        vm.expectEmit(true, true, true, true, address(vault));
        emit Unpaused();
        vm.prank(governance);
        vault.unpause();
    }

    function test_RevertWhen_NonGuardianPause() external {
        vm.expectRevert();
        vm.prank(alice);
        vault.pause();
    }

    function test_RevertWhen_DepositWhilePaused() external {
        vm.prank(governance);
        vault.pause();

        asset.mint(alice, 5 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 5 * DECIMALS);

        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(5 * DECIMALS, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            INIT VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_InitializeZeroAddress() external {
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        OllaCore newVault = OllaCore(address(proxy));
        MockAccountingStakingManager newStakingManager = new MockAccountingStakingManager();

        address newGovernance = makeAddr("governance");
        StAztec newStAztec = new StAztec(address(newVault));

        address newWithdrawalQueue = makeAddr("withdrawalQueue");
        MockRewardsVault newRewardsVault = new MockRewardsVault(asset, address(coreImplementation));
        address newSafetyModule = makeAddr("safetyModule");

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "asset_"));
        newVault.initialize(
            IERC20(address(0)),
            newStAztec,
            newStakingManager,
            0,
            5_000,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stAztec_"));
        newVault.initialize(
            asset,
            IStAztec(address(0)),
            newStakingManager,
            0,
            5_000,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stakingManager_"));
        newVault.initialize(
            asset,
            newStAztec,
            IStakingManager(address(0)),
            0,
            5_000,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "governance_"));
        newVault.initialize(
            asset,
            newStAztec,
            newStakingManager,
            0,
            5_000,
            address(0),
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "withdrawalQueue_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, 0, 5_000, newGovernance, address(0), newRewardsVault, newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "rewardsVault_"));
        newVault.initialize(
            asset,
            newStAztec,
            newStakingManager,
            0,
            5_000,
            newGovernance,
            newWithdrawalQueue,
            IRewardsVault(address(0)),
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "safetyModule_"));
        newVault.initialize(
            asset,
            newStAztec,
            newStakingManager,
            0,
            5_000,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_SyncBufferedWithBalance_ReconcilesExcessBalance() external {
        uint256 assets = 10 * DECIMALS;
        uint256 bonus = 2 * DECIMALS;

        _performDeposit(alice, assets);
        asset.mint(address(vault), bonus);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BufferedAssetsReconciled(bonus, assets + bonus, address(vault));
        vault.exposedSyncBufferedWithBalance();

        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.bufferedAssets, assets + bonus, "buffered assets reconciled");
    }

    function test_RevertWhen_BufferedBalanceBelowActual() external {
        uint256 assets = 5 * DECIMALS;

        vault.exposedIncreaseBuffered(assets);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCore__BufferedBalanceMismatch.selector, assets, 0));
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
        vault.deposit(assets, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed recipient, uint256 assets, uint256 shares);
    event BufferedAssetsReconciled(uint256 delta, uint256 newBufferedAssets, address indexed recipient);

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
}
