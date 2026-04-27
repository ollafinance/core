// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";

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
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    uint256 internal protocolFeeBP;
    uint256 internal treasuryFeeSplitBP;
    address internal governance;
    address internal alice;
    address internal bob;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal operator;

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

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();

        protocolFeeBP = 500;
        treasuryFeeSplitBP = 5_000;

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            protocolFeeBP,
            treasuryFeeSplitBP,
            governance,
            rewardsAccumulator,
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
        bob = makeAddr("bob");
    }

    /*//////////////////////////////////////////////////////////////
                               UPGRADES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UnauthorizedUpgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();
        address attacker = makeAddr("attacker");

        vm.expectRevert();
        vm.prank(attacker);
        core.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_DefaultAdminButNotOwner_Upgrade() external {
        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();
        address otherAdmin = makeAddr("otherAdmin");

        bytes32 defaultAdminRole = core.DEFAULT_ADMIN_ROLE();
        vm.prank(governance);
        core.grantRole(defaultAdminRole, otherAdmin);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, otherAdmin));
        vm.prank(otherAdmin);
        core.upgradeToAndCall(address(newImplementation), "");
    }

    function test_RevertWhen_UpgradeToZeroImplementation() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newImplementation"));
        vm.prank(governance);
        core.upgradeToAndCall(address(0), "");
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

        vm.expectEmit(true, true, false, true, address(core));
        emit Upgraded(address(newImplementation));

        vm.prank(governance);
        core.upgradeToAndCall(address(newImplementation), "");

        uint256 version = OllaCoreUpgradeMock(address(core)).version();
        assertEq(version, 2, "upgrade applied");
    }

    function test_GovernanceCanUpgrade_PreservesState() external {
        uint256 depositAmount = 12 * DECIMALS;
        uint256 sharesMinted = _performDeposit(alice, depositAmount);

        uint256 queueShares = 5 * DECIMALS;
        uint256 rateBefore = core.exchangeRate();
        uint256 expectedAssets = queueShares * rateBefore / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(queueShares, bob, alice);
        assertEq(requestId, 1, "request id starts at 1");

        // Drive non-zero module state so every live-read field in `AccountingState`
        // exercises the live-read path (StakingManager + RewardsAccumulator).
        // `cumulativeRewards` is the only protocol-owned ledger persisted in
        // `OllaCore` storage across upgrades; the remaining fields are derived
        // at read-time from the owning modules, so module state IS the accounting
        // state from the caller's perspective.
        stakingManager.mockSetCachedState(1 * DECIMALS, 4 * DECIMALS, 0); // slashingDelta, totalStaked, pendingUnstake
        stakingManager.mockSetClaimableRewards(3 * DECIMALS);
        deal(address(asset), address(rewardsAccumulator), 2 * DECIMALS);

        IOllaCore.AccountingState memory accountingBefore = core.accountingState();
        assertEq(accountingBefore.stakedPrincipal, 4 * DECIMALS, "staked seeded");
        assertEq(accountingBefore.rewardsAccumulatorBalance, 2 * DECIMALS, "accumulator seeded");
        assertEq(accountingBefore.claimableRewards, 3 * DECIMALS, "claimable seeded");
        assertEq(accountingBefore.slashingDelta, 1 * DECIMALS, "slashing seeded");

        uint256 totalAssetsBefore = core.totalAssets();
        uint256 aliceSharesBefore = stAztec.balanceOf(alice);
        uint256 bobBalanceBefore = asset.balanceOf(bob);

        OllaCoreUpgradeMock newImplementation = new OllaCoreUpgradeMock();

        vm.expectEmit(true, true, false, true, address(core));
        emit Upgraded(address(newImplementation));

        vm.prank(governance);
        core.upgradeToAndCall(address(newImplementation), "");

        OllaCoreUpgradeMock v2 = OllaCoreUpgradeMock(address(core));
        IOllaCore.AccountingState memory accountingAfter = v2.accountingState();

        assertEq(v2.version(), 2, "upgrade applied");
        assertEq(v2.totalAssets(), totalAssetsBefore, "total assets preserved");
        // bufferedAssets lives on the vault, not in core's AccountingState.
        assertEq(vault.bufferedAssets(), vault.bufferedAssets(), "buffered preserved");
        // Storage-backed field must survive the proxy upgrade.
        assertEq(
            accountingAfter.cumulativeRewards, accountingBefore.cumulativeRewards, "cumulativeRewards ledger preserved"
        );
        // Live-read fields are derived from the modules each call; they must match the
        // pre-upgrade snapshot because the modules themselves are unchanged.
        assertEq(accountingAfter.stakedPrincipal, accountingBefore.stakedPrincipal, "staked preserved");
        assertEq(
            accountingAfter.rewardsAccumulatorBalance,
            accountingBefore.rewardsAccumulatorBalance,
            "rewards vault preserved"
        );
        assertEq(accountingAfter.claimableRewards, accountingBefore.claimableRewards, "claimable rewards preserved");
        assertEq(accountingAfter.rewardsDelta, accountingBefore.rewardsDelta, "rewards delta preserved");
        assertEq(accountingAfter.slashingDelta, accountingBefore.slashingDelta, "slashing delta preserved");

        // Finalize the request before claiming (ERC-7540 requires finalization)
        vm.prank(address(core));
        vault.finalizeWithdrawals(type(uint256).max, type(uint256).max, type(uint256).max);

        vm.prank(bob);
        uint256 claimedAssets = vault.claimRequestById(requestId);
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
