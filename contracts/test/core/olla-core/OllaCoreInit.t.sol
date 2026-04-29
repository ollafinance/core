// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreInitTest is Test {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event Paused(address account);
    event Unpaused(address account);

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
    address internal alice;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

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
        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

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
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_InitializeSetsCoreAddresses() external view {
        assertEq(core.asset(), address(asset), "asset set");
        assertEq(core.stAztec(), address(stAztec), "stAztec set");
        assertEq(core.stakingManager(), address(stakingManager), "staking manager set");
        assertEq(core.owner(), governance, "owner set");
        assertEq(core.rewardsAccumulator(), address(rewardsAccumulator), "rewards vault set");
        assertEq(core.safetyModule(), address(safetyModule), "safety module set");
        assertEq(core.targetBufferedAssets(), 0, "target buffered assets init");
        IOllaCore.LatestReport memory report = core.latestReport();
        assertEq(report.exchangeRate, 1e18, "exchange rate init");
        assertEq(report.totalAssets, 0, "lastTotalAssets init");
    }

    function test_RevertWhen_Reinitialize() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_InitializeStartsPaused() external {
        OllaCoreHarness coreImpl = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImpl), "");
        OllaCoreHarness freshCore = OllaCoreHarness(address(proxy));
        OllaVault freshVaultImpl = new OllaVault();
        ERC1967Proxy freshVaultProxy = new ERC1967Proxy(address(freshVaultImpl), "");
        OllaVault freshVault = OllaVault(address(freshVaultProxy));
        StAztec freshStAztec = new StAztec(address(freshVault));

        freshCore.initialize(
            asset, freshStAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );

        assertTrue(freshCore.paused(), "core should be paused after initialize");
    }

    function test_GuardianCanPauseAndUnpause() external {
        vm.expectEmit(true, true, true, true, address(core));
        emit Paused(governance);
        vm.prank(governance);
        core.pause();

        vm.expectEmit(true, true, true, true, address(core));
        emit Unpaused(governance);
        vm.prank(governance);
        core.unpause();
    }

    function test_RevertWhen_NonGuardianPause() external {
        vm.expectRevert();
        vm.prank(alice);
        core.pause();
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
        OllaCore newCore = OllaCore(address(proxy));
        MockAccountingStakingManager newStakingManager = new MockAccountingStakingManager();

        address newGovernance = makeAddr("governance");
        OllaVault newVaultImpl = new OllaVault();
        ERC1967Proxy newVaultProxy = new ERC1967Proxy(address(newVaultImpl), "");
        OllaVault newVault = OllaVault(address(newVaultProxy));
        StAztec newStAztec = new StAztec(address(newVault));

        MockRewardsAccumulator newRewardsAccumulator = new MockRewardsAccumulator(asset, address(newCore));
        address newSafetyModule = makeAddr("safetyModule");

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "asset_"));
        newCore.initialize(
            IERC20(address(0)),
            newStAztec,
            newStakingManager,
            0,
            5_000,
            newGovernance,
            newRewardsAccumulator,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stAztec_"));
        newCore.initialize(
            asset,
            IStAztec(address(0)),
            newStakingManager,
            0,
            5_000,
            newGovernance,
            newRewardsAccumulator,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stakingManager_"));
        newCore.initialize(
            asset,
            newStAztec,
            IStakingManager(address(0)),
            0,
            5_000,
            newGovernance,
            newRewardsAccumulator,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "governanceContract_"));
        newCore.initialize(
            asset, newStAztec, newStakingManager, 0, 5_000, address(0), newRewardsAccumulator, newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "rewardsAccumulator_"));
        newCore.initialize(
            asset,
            newStAztec,
            newStakingManager,
            0,
            5_000,
            newGovernance,
            IRewardsAccumulator(address(0)),
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "safetyModule_"));
        newCore.initialize(
            asset, newStAztec, newStakingManager, 0, 5_000, newGovernance, newRewardsAccumulator, address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ERROR CASES
    //////////////////////////////////////////////////////////////*/

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
