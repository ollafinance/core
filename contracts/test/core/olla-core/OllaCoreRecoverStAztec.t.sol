// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";

contract OllaCoreRecoverStAztecTest is Test {
    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event StAztecRecovered(uint256 amount, address indexed recipient);

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
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();

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
                              STAZTEC RECOVERY
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RecoverStAztec_NotAdmin() external {
        uint256 shares = _performDeposit(alice, 8 * DECIMALS);
        uint256 recoverAmount = shares / 2;

        vm.prank(alice);
        stAztec.transfer(address(vault), recoverAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.recoverStAztec(alice, recoverAmount);
    }

    function test_RecoverStAztec_DefaultRecipientIsGovernance() external {
        uint256 shares = _performDeposit(alice, 12 * DECIMALS);
        uint256 recoverAmount = shares / 3;

        vm.prank(alice);
        stAztec.transfer(address(vault), recoverAmount);

        uint256 vaultBalanceBefore = stAztec.balanceOf(address(vault));
        uint256 governanceBalanceBefore = stAztec.balanceOf(governance);

        vm.expectEmit(true, true, true, true, address(vault));
        emit StAztecRecovered(recoverAmount, governance);

        vm.prank(governance);
        vault.recoverStAztec(address(0), recoverAmount);

        assertEq(stAztec.balanceOf(address(vault)), vaultBalanceBefore - recoverAmount, "vault shares debited");
        assertEq(stAztec.balanceOf(governance), governanceBalanceBefore + recoverAmount, "governance receives shares");
    }

    /*//////////////////////////////////////////////////////////////
                    REBALANCE PAUSE GUARD (C4)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RecoverStAztec_DuringRebalancePause() external {
        uint256 shares = _performDeposit(alice, 8 * DECIMALS);
        uint256 recoverAmount = shares / 4;

        vm.prank(alice);
        stAztec.transfer(address(vault), recoverAmount);

        // Set gas threshold extremely high so PullUnstaked step returns early,
        // keeping the rebalance mid-cycle with _rebalancePaused = true.
        vm.prank(governance);
        vault.setRebalanceGasThreshold(type(uint256).max);

        // Grant operator role and trigger rebalance — it will pause at PullUnstaked
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.prank(governance);
        vault.grantRole(operatorRole, address(this));

        vault.rebalance();

        // Verify rebalance is paused (stuck mid-cycle)
        assertTrue(vault.isRebalancePaused(), "rebalance should be paused mid-cycle");

        // Attempt recoverStAztec during rebalance pause
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RebalancePaused.selector));
        vm.prank(governance);
        vault.recoverStAztec(alice, recoverAmount);
    }
}
