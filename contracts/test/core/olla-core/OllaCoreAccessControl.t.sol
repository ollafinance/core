// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";

contract OllaCoreAccessControlTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProtocolFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
    event TreasuryFeeSplitUpdated(uint256 oldSplitBP, uint256 newSplitBP);
    event GovernanceProposed(address oldGovernance, address newGovernance);
    event GovernanceAccepted(address oldGovernance, address newGovernance);
    event GovernanceProposalCancelled(address governance, address pendingGovernance);
    event RewardsVaultUpdated(address oldRewardsVault, address newRewardsVault);
    event TargetBufferedAssetsUpdated(uint256 oldBuffer, uint256 newBuffer);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BP_DIVISOR = 10_000;
    uint256 internal constant INITIAL_PROTOCOL_FEE_BP = 500;
    uint256 internal constant INITIAL_TREASURY_SPLIT_BP = 5_000;

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    address internal governance;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    MockWithdrawalQueue internal withdrawalQueue;
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
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(coreImplementation));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            INITIAL_PROTOCOL_FEE_BP,
            INITIAL_TREASURY_SPLIT_BP,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        alice = makeAddr("alice");
    }

    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonAdminSetsProtocolFeeBP() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setProtocolFeeBP(100);
    }

    function test_RevertWhen_NonAdminSetsTreasuryFeeSplitBP() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setTreasuryFeeSplitBP(100);
    }

    function test_RevertWhen_NonAdminProposesGovernance() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.proposeGovernance(alice);
    }

    function test_RevertWhen_NonAdminSetsRewardsVault() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setRewardsVault(IRewardsVault(alice));
    }

    function test_RevertWhen_NonAdminSetsTargetBufferedAssets() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setTargetBufferedAssets(1);
    }

    /*//////////////////////////////////////////////////////////////
                         INVALID VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ProtocolFeeBPExceedsMax() external {
        uint256 aboveMax = vault.MAX_PROTOCOL_FEE_BP() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, aboveMax));
        vault.setProtocolFeeBP(aboveMax);
    }

    function test_RevertWhen_TreasuryFeeSplitBPExceedsMax() external {
        uint256 aboveMax = vault.MAX_TREASURY_SPLIT_BP() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, aboveMax));
        vault.setTreasuryFeeSplitBP(aboveMax);
    }

    function test_RevertWhen_TreasuryFeeSplitBPBelowMin() external {
        uint256 belowMin = vault.MIN_TREASURY_SPLIT_BP() - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, belowMin));
        vault.setTreasuryFeeSplitBP(belowMin);
    }

    function test_RevertWhen_GovernanceIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newGovernance"));
        vm.prank(governance);
        vault.proposeGovernance(address(0));
    }

    function test_RevertWhen_RewardsVaultIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newRewardsVault"));
        vm.prank(governance);
        vault.setRewardsVault(IRewardsVault(address(0)));
    }

    function test_SetTargetBufferedAssets_AllowsZero() external {
        uint256 oldBuffer = vault.targetBufferedAssets();

        vm.expectEmit(true, true, true, true, address(vault));
        emit TargetBufferedAssetsUpdated(oldBuffer, 0);

        vm.prank(governance);
        vault.setTargetBufferedAssets(0);

        assertEq(vault.targetBufferedAssets(), 0, "target buffer set to zero");
    }

    /*//////////////////////////////////////////////////////////////
                         SUCCESSFUL UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_UpdatesAndEmits() external {
        uint256 oldFeeBP = vault.protocolFeeBP();
        uint256 newFeeBP = 1000;

        vm.expectEmit(true, true, true, true, address(vault));
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);

        vm.prank(governance);
        vault.setProtocolFeeBP(newFeeBP);

        assertEq(vault.protocolFeeBP(), newFeeBP, "protocol fee updated");
    }

    function test_SetTreasuryFeeSplitBP_UpdatesAndEmits() external {
        uint256 oldSplitBP = vault.treasuryFeeSplitBP();
        uint256 newSplitBP = 7_000;

        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);

        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(newSplitBP);

        assertEq(vault.treasuryFeeSplitBP(), newSplitBP, "treasury split updated");
    }

    function test_ProposeGovernance_UpdatesAndEmits() external {
        address newGovernance = makeAddr("newGovernance");

        vm.expectEmit(true, true, true, true, address(vault));
        emit GovernanceProposed(governance, newGovernance);

        vm.prank(governance);
        vault.proposeGovernance(newGovernance);

        assertEq(vault.pendingGovernance(), newGovernance, "pending governance updated");
    }

    function test_SetRewardsVault_UpdatesAndEmits() external {
        address oldRewardsVault = vault.rewardsVault();
        address newRewardsVault = makeAddr("newRewardsVault");

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsVaultUpdated(oldRewardsVault, newRewardsVault);

        vm.prank(governance);
        vault.setRewardsVault(IRewardsVault(newRewardsVault));

        assertEq(vault.rewardsVault(), newRewardsVault, "rewards vault updated");
    }

    function test_SetTargetBufferedAssets_UpdatesAndEmits() external {
        uint256 oldBuffer = vault.targetBufferedAssets();
        uint256 newBuffer = oldBuffer + 1;

        vm.expectEmit(true, true, true, true, address(vault));
        emit TargetBufferedAssetsUpdated(oldBuffer, newBuffer);

        vm.prank(governance);
        vault.setTargetBufferedAssets(newBuffer);

        assertEq(vault.targetBufferedAssets(), newBuffer, "target buffer updated");
    }

    /*//////////////////////////////////////////////////////////////
                            BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_AllowsZero() external {
        vm.prank(governance);
        vault.setProtocolFeeBP(0);
        assertEq(vault.protocolFeeBP(), 0, "protocol fee set to zero");
    }

    function test_SetProtocolFeeBP_AllowsMax() external {
        uint256 maxFee = vault.MAX_PROTOCOL_FEE_BP();
        vm.prank(governance);
        vault.setProtocolFeeBP(maxFee);
        assertEq(vault.protocolFeeBP(), maxFee, "protocol fee set to max");
    }

    function test_SetTreasuryFeeSplitBP_AllowsMin() external {
        uint256 minSplit = vault.MIN_TREASURY_SPLIT_BP();
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(minSplit);
        assertEq(vault.treasuryFeeSplitBP(), minSplit, "treasury split set to min");
    }

    function test_SetTreasuryFeeSplitBP_AllowsMax() external {
        uint256 maxSplit = vault.MAX_TREASURY_SPLIT_BP();
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(maxSplit);
        assertEq(vault.treasuryFeeSplitBP(), maxSplit, "treasury split set to max");
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetProtocolFeeBP_ValidRange(uint256 newFeeBP) external {
        uint256 maxProtocolFee = vault.MAX_PROTOCOL_FEE_BP();
        newFeeBP = bound(newFeeBP, 0, maxProtocolFee);

        uint256 oldFeeBP = vault.protocolFeeBP();

        vm.expectEmit(true, true, true, true, address(vault));
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);

        vm.prank(governance);
        vault.setProtocolFeeBP(newFeeBP);

        assertEq(vault.protocolFeeBP(), newFeeBP, "protocol fee fuzz");
    }

    function testFuzz_SetProtocolFeeBP_InvalidRange(uint256 newFeeBP) external {
        uint256 maxProtocolFee = vault.MAX_PROTOCOL_FEE_BP();
        newFeeBP = bound(newFeeBP, maxProtocolFee + 1, type(uint256).max);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, newFeeBP));
        vault.setProtocolFeeBP(newFeeBP);
    }

    function testFuzz_SetTreasuryFeeSplitBP_ValidRange(uint256 newSplitBP) external {
        uint256 minSplit = vault.MIN_TREASURY_SPLIT_BP();
        uint256 maxSplit = vault.MAX_TREASURY_SPLIT_BP();
        newSplitBP = bound(newSplitBP, minSplit, maxSplit);

        uint256 oldSplitBP = vault.treasuryFeeSplitBP();

        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);

        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(newSplitBP);

        assertEq(vault.treasuryFeeSplitBP(), newSplitBP, "treasury split fuzz");
    }

    function testFuzz_SetTreasuryFeeSplitBP_InvalidRange_AboveMax(uint256 newSplitBP) external {
        uint256 maxSplit = vault.MAX_TREASURY_SPLIT_BP();
        newSplitBP = bound(newSplitBP, maxSplit + 1, type(uint256).max);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, newSplitBP));
        vault.setTreasuryFeeSplitBP(newSplitBP);
    }

    function testFuzz_SetTreasuryFeeSplitBP_InvalidRange_BelowMin(uint256 newSplitBP) external {
        uint256 minSplit = vault.MIN_TREASURY_SPLIT_BP();
        newSplitBP = bound(newSplitBP, 0, minSplit - 1);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, newSplitBP));
        vault.setTreasuryFeeSplitBP(newSplitBP);
    }

    function testFuzz_ProposeGovernance_NonZeroAddress(address newGovernance) external {
        vm.assume(newGovernance != address(0));

        vm.prank(governance);
        vault.proposeGovernance(newGovernance);

        assertEq(vault.pendingGovernance(), newGovernance, "governance fuzz");
    }

    function testFuzz_SetRewardsVault_NonZeroAddress(address newRewardsVault) external {
        vm.assume(newRewardsVault != address(0));

        address oldRewardsVault = vault.rewardsVault();

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsVaultUpdated(oldRewardsVault, newRewardsVault);

        vm.prank(governance);
        vault.setRewardsVault(IRewardsVault(newRewardsVault));

        assertEq(vault.rewardsVault(), newRewardsVault, "rewards vault fuzz");
    }

    /*//////////////////////////////////////////////////////////////
                    GOVERNANCE ROLE TRANSFER (C2)
    //////////////////////////////////////////////////////////////*/

    // NOTE: test_AcceptGovernance_TransfersAllRoles moved to OllaCoreGovernanceTransfer.t.sol
    // which uses real satellite contracts (AccessControlUpgradeable) instead of lightweight mocks.

    function test_RevertWhen_PendingGovernanceAlreadySet() external {
        address newGovernance = makeAddr("newGovernance");
        address secondGovernance = makeAddr("secondGovernance");

        vm.prank(governance);
        vault.proposeGovernance(newGovernance);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__PendingGovernanceAlreadySet.selector, newGovernance));
        vm.prank(governance);
        vault.proposeGovernance(secondGovernance);
    }

    function test_RevertWhen_NonPendingAcceptsGovernance() external {
        address newGovernance = makeAddr("newGovernance");

        vm.prank(governance);
        vault.proposeGovernance(newGovernance);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__UnauthorizedPendingGovernance.selector, governance));
        vm.prank(governance);
        vault.acceptGovernance();
    }

    function test_CancelGovernanceProposal_ClearsPending() external {
        address newGovernance = makeAddr("newGovernance");

        vm.prank(governance);
        vault.proposeGovernance(newGovernance);

        vm.expectEmit(true, true, true, true, address(vault));
        emit GovernanceProposalCancelled(governance, newGovernance);

        vm.prank(governance);
        vault.cancelGovernanceProposal();

        assertEq(vault.pendingGovernance(), address(0), "pending governance cleared");
    }

    function test_RevertWhen_CancelWithoutPending() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__NoPendingGovernance.selector));
        vm.prank(governance);
        vault.cancelGovernanceProposal();
    }
}
