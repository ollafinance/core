// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";

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
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";

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
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
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
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
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
                              STAZTEC RECOVERY
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RecoverStAztec_NotAdmin() external {
        uint256 shares = _performDeposit(alice, 8 * DECIMALS);
        uint256 recoverAmount = shares / 2;

        vm.prank(alice);
        stAztec.transfer(address(vault), recoverAmount);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
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
                    REBALANCE IN PROGRESS GUARD (C4)
    //////////////////////////////////////////////////////////////*/

    function test_RecoverStAztec_SucceedsDuringRebalanceInProgress() external {
        uint256 shares = _performDeposit(alice, 8 * DECIMALS);
        uint256 recoverAmount = shares / 4;

        vm.prank(alice);
        stAztec.transfer(address(vault), recoverAmount);

        // Trigger rebalance with limited gas so it stops mid-cycle at PullUnstaked.
        // Advance past the 1-hour rebalance cooldown initialised in OllaCore.initialize()
        vm.warp(block.timestamp + 1 hours);

        // Try a range of gas stipends to find one that stops at PullUnstaked
        uint256 selectedGas;
        uint256 snapshotId = vm.snapshotState();
        uint256[6] memory gasOptions = [uint256(120_000), 140_000, 160_000, 180_000, 200_000, 220_000];
        for (uint256 i; i < gasOptions.length; ++i) {
            vm.revertToState(snapshotId);
            (bool success,) = address(core).call{ gas: gasOptions[i] }(abi.encodeCall(core.rebalance, ()));
            if (!success) continue;
            IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
            if (progress.step == IOllaCore.RebalanceStep.PullUnstaked) {
                selectedGas = gasOptions[i];
                break;
            }
        }
        vm.revertToState(snapshotId);
        assertGt(selectedGas, 0, "should find gas stipend that stops at PullUnstaked");

        (bool ok,) = address(core).call{ gas: selectedGas }(abi.encodeCall(core.rebalance, ()));
        assertTrue(ok, "rebalance call should succeed");

        // Verify rebalance is in progress (stuck mid-cycle)
        assertNotEq(
            uint256(core.rebalanceProgress().step),
            uint256(IOllaCore.RebalanceStep.Done),
            "rebalance should be in progress mid-cycle"
        );

        // In the vault-core split, recoverStAztec lives on the vault and is not
        // gated by core's whenRebalanceDone modifier. It succeeds during rebalance.
        uint256 aliceBalanceBefore = stAztec.balanceOf(alice);
        vm.prank(governance);
        vault.recoverStAztec(alice, recoverAmount);
        assertEq(stAztec.balanceOf(alice) - aliceBalanceBefore, recoverAmount, "alice receives recovered stAztec");
    }
}
