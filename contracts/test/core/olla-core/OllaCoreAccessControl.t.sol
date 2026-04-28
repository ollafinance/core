// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { OwnableUpgradeable } from "@oz-upgradeable/access/OwnableUpgradeable.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { SafetyModule } from "src/safetymodule/SafetyModule.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreAccessControlTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProtocolFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
    event TreasuryFeeSplitUpdated(uint256 oldSplitBP, uint256 newSplitBP);
    event SafetyModuleUpdated(address oldSafetyModule, address newSafetyModule);
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
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    address internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            INITIAL_PROTOCOL_FEE_BP,
            INITIAL_TREASURY_SPLIT_BP,
            governance,
            rewardsAccumulator,
            address(safetyModule)
        );

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
                          ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonOwnerSetsProtocolFeeBP() external {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        core.setProtocolFeeBP(100);
    }

    function test_RevertWhen_NonOwnerSetsTreasuryFeeSplitBP() external {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        core.setTreasuryFeeSplitBP(100);
    }

    function test_RevertWhen_NonOwnerSetsSafetyModule() external {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        core.setSafetyModule(alice);
    }

    function test_RevertWhen_NonOwnerSetsTargetBufferedAssets() external {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        core.setTargetBufferedAssets(1);
    }

    function test_RevertWhen_RenounceOwnership() external {
        vm.expectRevert(bytes("renouncing ownership not allowed"));
        vm.prank(governance);
        core.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                         INVALID VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ProtocolFeeBPExceedsMax() external {
        uint256 aboveMax = core.MAX_PROTOCOL_FEE_BP() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, aboveMax));
        core.setProtocolFeeBP(aboveMax);
    }

    function test_RevertWhen_TreasuryFeeSplitBPExceedsMax() external {
        uint256 aboveMax = core.MAX_TREASURY_SPLIT_BP() + 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, aboveMax));
        core.setTreasuryFeeSplitBP(aboveMax);
    }

    function test_RevertWhen_TreasuryFeeSplitBPBelowMin() external {
        uint256 belowMin = core.MIN_TREASURY_SPLIT_BP() - 1;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, belowMin));
        core.setTreasuryFeeSplitBP(belowMin);
    }

    function test_RevertWhen_SafetyModuleIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newSafetyModule"));
        vm.prank(governance);
        core.setSafetyModule(address(0));
    }

    function test_SetTargetBufferedAssets_AllowsZero() external {
        uint256 oldBuffer = core.targetBufferedAssets();

        vm.expectEmit(true, true, true, true, address(core));
        emit TargetBufferedAssetsUpdated(oldBuffer, 0);

        vm.prank(governance);
        core.setTargetBufferedAssets(0);

        assertEq(core.targetBufferedAssets(), 0, "target buffer set to zero");
    }

    /*//////////////////////////////////////////////////////////////
                         SUCCESSFUL UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_UpdatesAndEmits() external {
        uint256 oldFeeBP = core.protocolFeeBP();
        uint256 newFeeBP = 1000;

        vm.expectEmit(true, true, true, true, address(core));
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);

        vm.prank(governance);
        core.setProtocolFeeBP(newFeeBP);

        assertEq(core.protocolFeeBP(), newFeeBP, "protocol fee updated");
    }

    function test_SetTreasuryFeeSplitBP_UpdatesAndEmits() external {
        uint256 oldSplitBP = core.treasuryFeeSplitBP();
        uint256 newSplitBP = 7_000;

        vm.expectEmit(true, true, true, true, address(core));
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);

        vm.prank(governance);
        core.setTreasuryFeeSplitBP(newSplitBP);

        assertEq(core.treasuryFeeSplitBP(), newSplitBP, "treasury split updated");
    }

    function test_SetSafetyModule_UpdatesAndEmits() external {
        address oldSafetyModule = core.safetyModule();
        MockSafetyModule newSafetyModule = new MockSafetyModule(address(core), address(vault));

        vm.expectEmit(true, true, true, true, address(core));
        emit SafetyModuleUpdated(oldSafetyModule, address(newSafetyModule));

        vm.prank(governance);
        core.setSafetyModule(address(newSafetyModule));

        assertEq(core.safetyModule(), address(newSafetyModule), "safety module updated");
    }

    function test_SetSafetyModule_PrimesAccountingTimestampOnNewModule() external {
        SafetyModule newSafetyModule =
            new SafetyModule(governance, governance, address(core), address(vault), 1_000 ether, 500, 6_000, 1 days);

        vm.warp(block.timestamp + 7 days);

        vm.prank(governance);
        core.setSafetyModule(address(newSafetyModule));

        assertEq(
            newSafetyModule.lastAccountingTimestamp(), block.timestamp, "new safety module timestamp should be primed"
        );
    }

    function test_RevertWhen_SafetyModuleCoreDoesNotMatch() external {
        MockSafetyModule wrongModule = new MockSafetyModule(makeAddr("wrongCore"), address(vault));

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSafetyModule.selector, address(wrongModule)));
        vm.prank(governance);
        core.setSafetyModule(address(wrongModule));
    }

    function test_SetTargetBufferedAssets_UpdatesAndEmits() external {
        uint256 oldBuffer = core.targetBufferedAssets();
        uint256 newBuffer = oldBuffer + 1;

        vm.expectEmit(true, true, true, true, address(core));
        emit TargetBufferedAssetsUpdated(oldBuffer, newBuffer);

        vm.prank(governance);
        core.setTargetBufferedAssets(newBuffer);

        assertEq(core.targetBufferedAssets(), newBuffer, "target buffer updated");
    }

    /*//////////////////////////////////////////////////////////////
                            BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_AllowsZero() external {
        vm.prank(governance);
        core.setProtocolFeeBP(0);
        assertEq(core.protocolFeeBP(), 0, "protocol fee set to zero");
    }

    function test_SetProtocolFeeBP_AllowsMax() external {
        uint256 maxFee = core.MAX_PROTOCOL_FEE_BP();
        vm.prank(governance);
        core.setProtocolFeeBP(maxFee);
        assertEq(core.protocolFeeBP(), maxFee, "protocol fee set to max");
    }

    function test_SetTreasuryFeeSplitBP_AllowsMin() external {
        uint256 minSplit = core.MIN_TREASURY_SPLIT_BP();
        vm.prank(governance);
        core.setTreasuryFeeSplitBP(minSplit);
        assertEq(core.treasuryFeeSplitBP(), minSplit, "treasury split set to min");
    }

    function test_SetTreasuryFeeSplitBP_AllowsMax() external {
        uint256 maxSplit = core.MAX_TREASURY_SPLIT_BP();
        vm.prank(governance);
        core.setTreasuryFeeSplitBP(maxSplit);
        assertEq(core.treasuryFeeSplitBP(), maxSplit, "treasury split set to max");
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetProtocolFeeBP_ValidRange(uint256 newFeeBP) external {
        uint256 maxProtocolFee = core.MAX_PROTOCOL_FEE_BP();
        newFeeBP = bound(newFeeBP, 0, maxProtocolFee);

        uint256 oldFeeBP = core.protocolFeeBP();

        vm.expectEmit(true, true, true, true, address(core));
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);

        vm.prank(governance);
        core.setProtocolFeeBP(newFeeBP);

        assertEq(core.protocolFeeBP(), newFeeBP, "protocol fee fuzz");
    }

    function testFuzz_SetProtocolFeeBP_InvalidRange(uint256 newFeeBP) external {
        uint256 maxProtocolFee = core.MAX_PROTOCOL_FEE_BP();
        newFeeBP = bound(newFeeBP, maxProtocolFee + 1, type(uint256).max);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, newFeeBP));
        core.setProtocolFeeBP(newFeeBP);
    }

    function testFuzz_SetTreasuryFeeSplitBP_ValidRange(uint256 newSplitBP) external {
        uint256 minSplit = core.MIN_TREASURY_SPLIT_BP();
        uint256 maxSplit = core.MAX_TREASURY_SPLIT_BP();
        newSplitBP = bound(newSplitBP, minSplit, maxSplit);

        uint256 oldSplitBP = core.treasuryFeeSplitBP();

        vm.expectEmit(true, true, true, true, address(core));
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);

        vm.prank(governance);
        core.setTreasuryFeeSplitBP(newSplitBP);

        assertEq(core.treasuryFeeSplitBP(), newSplitBP, "treasury split fuzz");
    }

    function testFuzz_SetTreasuryFeeSplitBP_InvalidRange_AboveMax(uint256 newSplitBP) external {
        uint256 maxSplit = core.MAX_TREASURY_SPLIT_BP();
        newSplitBP = bound(newSplitBP, maxSplit + 1, type(uint256).max);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, newSplitBP));
        core.setTreasuryFeeSplitBP(newSplitBP);
    }

    function testFuzz_SetTreasuryFeeSplitBP_InvalidRange_BelowMin(uint256 newSplitBP) external {
        uint256 minSplit = core.MIN_TREASURY_SPLIT_BP();
        newSplitBP = bound(newSplitBP, 0, minSplit - 1);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, newSplitBP));
        core.setTreasuryFeeSplitBP(newSplitBP);
    }

    function testFuzz_SetSafetyModule_AcceptsValidModule(uint256 salt) external {
        // Deploy a fresh MockSafetyModule with the correct CORE for each fuzz run.
        MockSafetyModule newModule = new MockSafetyModule{ salt: bytes32(salt) }(address(core), address(vault));

        address oldSafetyModule = core.safetyModule();

        vm.expectEmit(true, true, true, true, address(core));
        emit SafetyModuleUpdated(oldSafetyModule, address(newModule));

        vm.prank(governance);
        core.setSafetyModule(address(newModule));

        assertEq(core.safetyModule(), address(newModule), "safety module fuzz");
    }
}
