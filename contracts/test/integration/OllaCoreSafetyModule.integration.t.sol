// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { PausableUpgradeable } from "@oz-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { StAztec } from "src/core/StAztec.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

contract OllaCoreSafetyModuleHarness is OllaCore {
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

contract OllaCoreSafetyModuleTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CircuitBreakerTriggered(bytes32 reason);

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
    MockAccountingStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    SafetyModule internal safetyModule;
    address internal governance;
    address internal admin;
    address internal guardian;
    MockRewardsVault internal rewardsVault;
    address internal operator;
    address internal alice;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreSafetyModuleHarness coreImplementation = new OllaCoreSafetyModuleHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreSafetyModuleHarness(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        withdrawalQueue = new MockWithdrawalQueue();
        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        admin = makeAddr("admin");
        guardian = makeAddr("guardian");
        rewardsVault = new MockRewardsVault(asset, address(vault));
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        safetyModule = new SafetyModule(admin, guardian, address(vault), 1_000_000 * DECIMALS, 500, 6_000, 1 days);

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
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

    function _performRequestRedeem(address owner, uint256 shares, address recipient)
        internal
        returns (uint256 requestId)
    {
        vm.prank(owner);
        requestId = vault.requestRedeem(shares, recipient);
        return requestId;
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
        vault.exposedApplyAccountingUpdates(0, 60 * DECIMALS, 0, 0, 0);

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

    /*//////////////////////////////////////////////////////////////
                             CIRCUIT BREAKERS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAccounting_TriggersRateDropBreaker() external {
        _performDeposit(alice, 100 * DECIMALS);

        stakingManager.setSlashingDelta(10 * DECIMALS);

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(safetyModule.RATE_DROP());

        vault.updateAccounting();

        assertTrue(safetyModule.isPaused(), "rate-drop breaker should pause");
    }

    function test_UpdateAccounting_TriggersQueueRatioBreaker() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        _performRequestRedeem(alice, 80 * DECIMALS, alice);

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(safetyModule.QUEUE_RATIO());

        vault.updateAccounting();

        assertTrue(safetyModule.isPaused(), "queue ratio breaker should pause");
    }

    function test_UpdateAccounting_TriggersAccountingLivenessBreaker() external {
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(false, false, false, true, address(safetyModule));
        emit CircuitBreakerTriggered(safetyModule.ACCOUNTING_STALE());

        vault.updateAccounting();

        assertTrue(safetyModule.isPaused(), "accounting liveness breaker should pause");
        assertEq(
            safetyModule.lastAccountingTimestamp(), block.timestamp, "accounting timestamp should update on success"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL MINIMUM
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestRedeemBelowMinimum() external {
        uint256 minimum = 10 * DECIMALS;
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(minimum);

        _performDeposit(alice, 20 * DECIMALS);

        vm.expectRevert(
            abi.encodeWithSelector(ISafetyModule.SafetyModule__BelowWithdrawalMinimum.selector, 5 * DECIMALS, minimum)
        );
        _performRequestRedeem(alice, 5 * DECIMALS, alice);
    }

    function test_RequestRedeemAtMinimum_Succeeds() external {
        uint256 minimum = 10 * DECIMALS;
        vm.prank(admin);
        safetyModule.setWithdrawalMinimum(minimum);

        _performDeposit(alice, 20 * DECIMALS);

        uint256 requestId = _performRequestRedeem(alice, minimum, alice);

        assertEq(requestId, 1, "minimum request should succeed");
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSED FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DepositBlockedBySafetyModulePause() external {
        vm.prank(guardian);
        safetyModule.pause();

        asset.mint(alice, 10 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 10 * DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__SafetyModulePaused.selector));
        vm.prank(alice);
        vault.deposit(10 * DECIMALS, alice);
    }

    function test_RequestRedeem_AllowsWhenPaused() external {
        uint256 shares = _performDeposit(alice, 12 * DECIMALS);

        vm.prank(governance);
        vault.pause();

        vm.prank(guardian);
        safetyModule.pause();

        uint256 requestId = _performRequestRedeem(alice, shares / 2, alice);

        assertEq(requestId, 1, "request should succeed while paused");
    }

    function test_ClaimWithdrawal_AllowsWhenPaused() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);
        _performRequestRedeem(alice, shares / 2, alice);

        vm.prank(governance);
        vault.pause();

        uint256 claimed = vault.claimActiveRequest(alice);

        assertEq(claimed, 5 * DECIMALS, "claim should succeed while paused");
    }
}
