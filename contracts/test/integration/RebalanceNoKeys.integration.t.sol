// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract RebalanceNoKeysIntegrationTest is Test {
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant ACTIVATION_THRESHOLD = 32 * DECIMALS;

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal operator;
    address internal providerAdmin;
    address internal defaultAdmin;
    address internal user;

    function setUp() external {
        asset = new MockAztec(address(this));
        governance = makeAddr("governance");
        operator = makeAddr("operator");
        providerAdmin = makeAddr("providerAdmin");
        defaultAdmin = makeAddr("defaultAdmin");
        user = makeAddr("user");

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        rollup = new MockAztecRollup(IERC20(address(asset)), ACTIVATION_THRESHOLD);
        rollupRegistry = new MockAztecRollupRegistry(address(rollup));

        StakingManager stakingImplementation = new StakingManager();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImplementation), "");
        stakingManager = StakingManager(address(stakingProxy));

        StakingProviderRegistry registryImplementation = new StakingProviderRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(address(registryImplementation), "");
        stakingProviderRegistry = StakingProviderRegistry(address(registryProxy));

        stakingProviderRegistry.initialize(address(stakingManager), providerAdmin, providerAdmin, defaultAdmin);
        stakingManager.initialize(
            IERC20(address(asset)),
            address(rollupRegistry),
            address(rewardsAccumulator),
            address(core),
            address(stakingProviderRegistry),
            defaultAdmin
        );

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();
    }

    /// @notice When no keys are registered, rebalance completes gracefully without staking.
    /// @dev The StakeSurplus step catches the InsufficientKeys revert and advances,
    ///      leaving all funds in the buffer.
    function test_Rebalance_CompletesGracefully_WhenNoKeys() external {
        uint256 depositAmount = 50 * DECIMALS;

        asset.mint(user, depositAmount);
        vm.prank(user);
        asset.approve(address(vault), depositAmount);
        vm.prank(user);
        vault.deposit(depositAmount, user, 0);

        // Advance past rebalance cooldown (1 hour) so rebalance() can start a new cycle
        vm.warp(block.timestamp + 1 hours);

        vm.prank(operator);
        (,, uint256 stakedAmount, uint256 resultingBuffer) = core.rebalance();

        // Staking should gracefully return 0 when no keys are available
        assertEq(stakedAmount, 0, "should not stake when no keys");
        assertEq(resultingBuffer, depositAmount, "buffer should retain all deposited funds");

        // Verify the rebalance cycle completed
        IOllaCore.RebalanceProgress memory progress = core.rebalanceProgress();
        assertEq(uint256(progress.step), uint256(IOllaCore.RebalanceStep.Done), "rebalance should complete");
    }
}
