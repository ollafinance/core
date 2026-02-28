// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { IOllaGovernance } from "src/governance/IOllaGovernance.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title OllaGovernanceSetup
/// @notice Shared base test fixture for OllaGovernance test suites.
abstract contract OllaGovernanceSetup is Test {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MIN_DELAY = 1 days;
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaGovernance internal gov;
    OllaCore internal core;
    OllaVault internal vault;
    MockAztec internal asset;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;

    address internal admin; // proposer / executor / canceller
    address internal treasuryAddr;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        admin = makeAddr("admin");
        treasuryAddr = makeAddr("treasury");
        alice = makeAddr("alice");

        asset = new MockAztec(address(this));

        // ---- Deploy OllaGovernance (impl + proxy + init) ----
        OllaGovernance govImpl = new OllaGovernance();
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        ERC1967Proxy govProxy = new ERC1967Proxy(
            address(govImpl),
            abi.encodeCall(OllaGovernance.initialize, (MIN_DELAY, proposers, executors, admin, treasuryAddr))
        );
        gov = OllaGovernance(payable(address(govProxy)));

        // ---- Deploy OllaCore (impl + proxy) ----
        OllaCore coreImpl = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        core = OllaCore(address(coreProxy));

        // ---- Deploy OllaVault (impl + proxy) ----
        OllaVault vaultImpl = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), "");
        vault = OllaVault(address(vaultProxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        withdrawalQueue = new MockWithdrawalQueue();
        rewardsVault = new MockRewardsVault(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        // Initialize OllaCore with OllaGovernance as owner
        core.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            address(gov),
            rewardsVault,
            address(safetyModule)
        );

        // Initialize OllaVault
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), address(gov));

        // Wire core -> vault
        vm.prank(address(gov));
        core.setVault(address(vault));

        // Wire OllaGovernance -> OllaCore
        vm.prank(admin);
        gov.setCore(address(core));

        // Unpause (gov contract holds GUARDIAN_ROLE from OllaCore.initialize)
        vm.prank(address(gov));
        core.unpause();
        vm.prank(address(gov));
        vault.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          TIMELOCK HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Schedule + warp + execute a governance action.
    function _scheduleAndExecute(address target, bytes memory data) internal {
        _scheduleAndExecute(target, data, bytes32(0));
    }

    function _scheduleAndExecute(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(admin);
        gov.schedule(target, 0, data, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(admin);
        gov.execute(target, 0, data, bytes32(0), salt);
    }

    /// @notice Schedule only (no execute).
    function _schedule(address target, bytes memory data) internal returns (bytes32 id) {
        id = gov.hashOperation(target, 0, data, bytes32(0), bytes32(0));
        vm.prank(admin);
        gov.schedule(target, 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    }
}
