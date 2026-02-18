// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";

contract OllaCoreUpgradeHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedApplyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsVaultBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) external {
        _applyAccountingUpdates(
            newStakedPrincipal, newRewardsVaultBalance, newClaimableRewards, newRewardsDelta, newSlashingDelta
        );
    }
}

contract OllaCoreUpgradeMock is OllaCore {
    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public v2Value;

    /*//////////////////////////////////////////////////////////////
                             CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setV2Value(uint256 value) external {
        v2Value = value;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract OllaCoreUpgradeTest is Test {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event Upgraded(address indexed implementation);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreUpgradeHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    address internal governance;
    address internal alice;
    address internal bob;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal operator;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreUpgradeHarness coreImplementation = new OllaCoreUpgradeHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreUpgradeHarness(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(coreImplementation));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
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
                               UPGRADES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UnauthorizedUpgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();
        address attacker = makeAddr("attacker");

        vm.expectRevert();
        vm.prank(attacker);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_DefaultAdminButNotGovernance_Upgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();
        address otherAdmin = makeAddr("otherAdmin");

        bytes32 defaultAdminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(governance);
        vault.grantRole(defaultAdminRole, otherAdmin);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCore__UnauthorizedGovernance.selector, otherAdmin));
        vm.prank(otherAdmin);
        vault.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_UpgradeToZeroImplementation() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newImplementation"));
        vm.prank(governance);
        vault.upgradeToAndCall(address(0), "");
    }

    function test_RevertWhen_UpgradeCalledOnImplementationDirectly() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();
        OllaCore implementation = new OllaCore();

        vm.expectRevert();
        vm.prank(governance);
        implementation.upgradeToAndCall(address(newImplementation), "");
    }

    function test_GovernanceCanUpgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();

        vm.expectEmit(true, true, false, true, address(vault));
        emit Upgraded(address(newImplementation));

        vm.prank(governance);
        vault.upgradeToAndCall(address(newImplementation), "");

        uint256 version = OllaCoreUpgradeMock(address(vault)).version();
        assertEq(version, 2, "upgrade applied");
    }

    function test_GovernanceCanUpgrade_PreservesState() external {
        uint256 depositAmount = 12 * DECIMALS;
        uint256 sharesMinted = _performDeposit(alice, depositAmount);

        uint256 queueShares = 5 * DECIMALS;
        uint256 rateBefore = vault.exchangeRate();
        uint256 expectedAssets = queueShares * rateBefore / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(queueShares, bob);
        assertEq(requestId, 1, "request id starts at 1");

        vm.prank(operator);
        vault.exposedApplyAccountingUpdates(4 * DECIMALS, 2 * DECIMALS, 3 * DECIMALS, 1 * DECIMALS, 1 * DECIMALS);

        IOllaCore.AccountingState memory accountingBefore = vault.accountingState();
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 aliceSharesBefore = stAztec.balanceOf(alice);
        uint256 bobBalanceBefore = asset.balanceOf(bob);

        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();

        vm.expectEmit(true, true, false, true, address(vault));
        emit Upgraded(address(newImplementation));

        vm.prank(governance);
        vault.upgradeToAndCall(address(newImplementation), "");

        OllaCoreUpgradeMock v2 = OllaCoreUpgradeMock(address(vault));
        IOllaCore.AccountingState memory accountingAfter = v2.accountingState();

        assertEq(v2.version(), 2, "upgrade applied");
        assertEq(v2.totalAssets(), totalAssetsBefore, "total assets preserved");
        assertEq(accountingAfter.bufferedAssets, accountingBefore.bufferedAssets, "buffered preserved");
        assertEq(accountingAfter.stakedPrincipal, accountingBefore.stakedPrincipal, "staked preserved");
        assertEq(accountingAfter.rewardsVaultBalance, accountingBefore.rewardsVaultBalance, "rewards vault preserved");
        assertEq(accountingAfter.claimableRewards, accountingBefore.claimableRewards, "claimable rewards preserved");
        assertEq(accountingAfter.rewardsDelta, accountingBefore.rewardsDelta, "rewards delta preserved");
        assertEq(accountingAfter.slashingDelta, accountingBefore.slashingDelta, "slashing delta preserved");

        vm.prank(alice);
        uint256 claimedAssets = v2.claimRequestById(requestId);
        assertEq(claimedAssets, expectedAssets, "request assets preserved");
        assertEq(asset.balanceOf(bob) - bobBalanceBefore, expectedAssets, "recipient receives assets");
        assertEq(stAztec.balanceOf(alice), aliceSharesBefore, "shares preserved");
        assertEq(sharesMinted - queueShares, aliceSharesBefore, "shares track request");

        v2.setV2Value(123);
        assertEq(v2.v2Value(), 123, "v2 storage works");
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
}
