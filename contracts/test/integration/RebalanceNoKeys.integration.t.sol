// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { MockAztecRollup } from "src/staking/mocks/MockAztecRollup.sol";
import { MockAztecRollupRegistry } from "src/staking/mocks/MockAztecRollupRegistry.sol";

contract RebalanceNoKeysIntegrationTest is Test {
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant ACTIVATION_THRESHOLD = 32 * DECIMALS;

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;
    MockAztecRollup internal rollup;
    MockAztecRollupRegistry internal rollupRegistry;
    WithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
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
        vault = OllaCore(address(coreProxy));

        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(vault));

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

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
            address(rewardsVault),
            address(vault),
            address(stakingProviderRegistry),
            defaultAdmin
        );

        withdrawalQueue.initialize(address(vault), governance, 180_000);

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );
        vm.prank(governance);
        vault.unpause();

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vm.stopPrank();
    }

    function test_Rebalance_RevertsWhen_NoKeys() external {
        uint256 depositAmount = 50 * DECIMALS;

        asset.mint(user, depositAmount);
        vm.prank(user);
        asset.approve(address(vault), depositAmount);
        vm.prank(user);
        vault.deposit(depositAmount, user, 0);

        vm.prank(governance);
        vault.setTargetBufferedAssets(0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__StakeFailed.selector, depositAmount));
        vault.rebalance();
    }
}
