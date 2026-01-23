// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { SafetyModule } from "src/core/SafetyModule.sol";
import { StAztec } from "src/core/StAztec.sol";
import { IOllaCore } from "src/interfaces/IOllaCore.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";
import { MockWithdrawalQueue } from "src/mocks/MockWithdrawalQueue.sol";

contract OllaCoreSafetyModuleHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedIncreaseRewardsVaultBalance(uint256 amount) external {
        _increaseRewardsVaultBalance(amount);
    }
}

contract OllaCoreSafetyModuleTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreSafetyModuleHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    SafetyModule internal safetyModule;
    address internal governance;
    address internal admin;
    address internal guardian;
    address internal rewardsVault;
    address internal operator;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreSafetyModuleHarness coreImplementation = new OllaCoreSafetyModuleHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreSafetyModuleHarness(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        withdrawalQueue = new MockWithdrawalQueue();
        governance = makeAddr("governance");
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        rewardsVault = makeAddr("rewardsVault");
        operator = makeAddr("operator");
        alice = makeAddr("alice");

        safetyModule = new SafetyModule(admin, guardian, address(vault), 0, 500, 6_000, 1 days);

        vault.initialize(
            asset, stAztec, stakingManager, governance, address(withdrawalQueue), rewardsVault, address(safetyModule)
        );

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address depositor, uint256 amount) internal returns (uint256 shares) {
        asset.mint(depositor, amount);
        vm.prank(depositor);
        asset.approve(address(vault), amount);
        vm.prank(depositor);
        shares = vault.deposit(amount, depositor);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                             DEPOSIT CAPS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DepositAboveCap() external {
        uint256 cap = 100 * DECIMALS;
        vm.prank(admin);
        safetyModule.setDepositCap(cap);

        uint256 depositAmount = cap + 1;
        asset.mint(alice, depositAmount);
        vm.prank(alice);
        asset.approve(address(vault), depositAmount);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__DepositCapExceeded.selector, depositAmount, 0));
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
    }

    function test_DepositAtCap_Succeeds() external {
        uint256 cap = 100 * DECIMALS;
        vm.prank(admin);
        safetyModule.setDepositCap(cap);

        uint256 shares = _performDeposit(alice, cap);

        assertEq(shares, cap, "shares minted at 1:1");
        assertEq(vault.totalAssets(), cap, "total assets at cap");
    }

    function test_RevertWhen_DepositUsesTotalAssetsForCap() external {
        uint256 cap = 150 * DECIMALS;
        vm.prank(admin);
        safetyModule.setDepositCap(cap);

        vm.prank(operator);
        vault.exposedIncreaseRewardsVaultBalance(60 * DECIMALS);

        uint256 depositAmount = 100 * DECIMALS;
        asset.mint(alice, depositAmount);
        vm.prank(alice);
        asset.approve(address(vault), depositAmount);

        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__DepositCapExceeded.selector, depositAmount, 60 * DECIMALS)
        );
        vm.prank(alice);
        vault.deposit(depositAmount, alice);
    }
}
