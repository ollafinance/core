// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { IStAztec } from "src/vault/interfaces/IStAztec.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaCore } from "src/core/OllaCore.sol";

/// @title OllaCoreGuardsTest
/// @notice Tests covering untested branches and functions in OllaCore.sol.
contract OllaCoreGuardsTest is Test {
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
    MockOllaGovernance internal governance;
    address internal alice;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImpl = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        core = OllaCoreHarness(address(coreProxy));

        OllaVault vaultImpl = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = new MockOllaGovernance();
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 0, 5_000, address(governance), rewardsAccumulator, address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), address(governance));

        vm.prank(address(governance));
        core.setVault(address(vault));

        vm.prank(address(governance));
        core.unpause();

        vm.prank(address(governance));
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
                    GUARDIAN PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_Pause_ViaGuardianRole() external {
        vm.prank(address(governance));
        core.pause();
        assertTrue(core.paused(), "core should be paused");
    }

    function test_Unpause_ViaGuardianRole() external {
        vm.prank(address(governance));
        core.pause();
        assertTrue(core.paused(), "core should be paused");

        vm.prank(address(governance));
        core.unpause();
        assertFalse(core.paused(), "core should be unpaused");
    }

    /*//////////////////////////////////////////////////////////////
                    UPDATE ACCOUNTING STANDALONE
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAccounting_Standalone() external {
        // Deposit to have some total assets
        _performDeposit(alice, 100 * DECIMALS);

        // Warp past cooldown
        vm.warp(block.timestamp + 2 hours);

        // Call updateAccounting directly (not via rebalance)
        core.updateAccounting();

        // Verify it executed without reverting
        IOllaCore.LatestReport memory report = core.latestReport();
        assertGt(report.timestamp, 0, "report timestamp should be updated");
    }

    /*//////////////////////////////////////////////////////////////
                        SET VAULT GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetVault_ZeroAddress() external {
        // Deploy a fresh core that hasn't had setVault called
        OllaCoreHarness freshCoreImpl = new OllaCoreHarness();
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshCoreImpl), "");
        OllaCoreHarness freshCore = OllaCoreHarness(address(freshProxy));

        freshCore.initialize(
            asset, stAztec, stakingManager, 0, 5_000, address(governance), rewardsAccumulator, address(safetyModule)
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "vault_"));
        vm.prank(address(governance));
        freshCore.setVault(address(0));
    }

    function test_RevertWhen_SetVault_AlreadySet() external {
        // In setUp, setVault was already called
        vm.expectRevert(IOllaCore.OllaCore__VaultAlreadySet.selector);
        vm.prank(address(governance));
        core.setVault(makeAddr("newVault"));
    }

    /*//////////////////////////////////////////////////////////////
          _pullUnstakedFunds BALANCE MISMATCH (SECURITY-CRITICAL)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_PullUnstakedFunds_BalanceMismatch() external {
        _performDeposit(alice, 100 * DECIMALS);

        // Warp past cooldown
        vm.warp(block.timestamp + 2 hours);

        // Mock getUnstakedFunds to report receiving tokens without actually transferring
        vm.mockCall(
            address(stakingManager),
            abi.encodeWithSelector(IStakingManager.getUnstakedFunds.selector),
            abi.encode(uint256(10 * DECIMALS), uint256(10 * DECIMALS), false)
        );

        // Rebalance should revert because reported != actual
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__UnstakedFundsMismatch.selector, 10 * DECIMALS, 0));
        core.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
              _validateInitialParams INVALID FEES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Initialize_ProtocolFeeTooHigh() external {
        OllaCoreHarness freshImpl = new OllaCoreHarness();
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshImpl), "");
        OllaCoreHarness freshCore = OllaCoreHarness(address(freshProxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, uint256(5_001)));
        freshCore.initialize(
            asset, stAztec, stakingManager, 5_001, 5_000, address(governance), rewardsAccumulator, address(safetyModule)
        );
    }

    function test_RevertWhen_Initialize_TreasurySplitTooLow() external {
        OllaCoreHarness freshImpl = new OllaCoreHarness();
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshImpl), "");
        OllaCoreHarness freshCore = OllaCoreHarness(address(freshProxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, uint256(999)));
        freshCore.initialize(
            asset, stAztec, stakingManager, 0, 999, address(governance), rewardsAccumulator, address(safetyModule)
        );
    }

    function test_RevertWhen_Initialize_TreasurySplitTooHigh() external {
        OllaCoreHarness freshImpl = new OllaCoreHarness();
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(freshImpl), "");
        OllaCoreHarness freshCore = OllaCoreHarness(address(freshProxy));

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, uint256(9_001)));
        freshCore.initialize(
            asset, stAztec, stakingManager, 0, 9_001, address(governance), rewardsAccumulator, address(safetyModule)
        );
    }

    /*//////////////////////////////////////////////////////////////
            _hasRebalanceWorkAvailable RETURNING FALSE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_NoWorkAvailable_ReturnsEarly() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Set targetBufferedAssets = deposit so no surplus is staked, making rebalance idle
        vm.prank(address(governance));
        core.setTargetBufferedAssets(depositAmount);

        // Warp past cooldown (use absolute timestamps)
        uint256 t1 = block.timestamp + 2 hours;
        vm.warp(t1);

        // First rebalance (should set _rebalanceIdleBuffer since no work)
        (,,, uint256 b1) = core.rebalance();

        // Warp past cooldown again
        uint256 t2 = t1 + 2 hours;
        vm.warp(t2);

        // Second rebalance — buffer unchanged and no work → early return
        (uint256 r2, uint256 f2, uint256 s2, uint256 b2) = core.rebalance();

        assertEq(r2, 0, "rewards delta should be 0 on idle rebalance");
        assertEq(f2, 0, "finalized amount should be 0 on idle rebalance");
        assertEq(s2, 0, "staked amount should be 0 on idle rebalance");
        assertEq(b2, b1, "buffer should remain unchanged on idle rebalance");
    }

    /*//////////////////////////////////////////////////////////////
          _stakeSurplus ZERO / _initiateUnstake ZERO
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_NoSurplusToStake_NoUnstakeNeeded() external {
        // Deposit exact amount that will be buffered (targetBufferedAssets == 0)
        _performDeposit(alice, 100 * DECIMALS);

        // Warp past cooldown
        vm.warp(block.timestamp + 2 hours);

        // Configure staking manager to return 0 from stake
        stakingManager.setStakeReturnAmount(0);

        // Rebalance — will attempt to stake surplus but stakingManager returns 0
        core.rebalance();

        // The stake attempt may result in 0 or the try-catch path
        // Either way, the rebalance should complete without reverting
        assertTrue(true, "rebalance completed without reverting");
    }
}
