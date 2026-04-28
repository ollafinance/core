// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";

contract OllaVaultFinalizeGasTest is Test {
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
    WithdrawalQueue internal withdrawalQueue;
    MockAccountingStakingManager internal stakingManager;
    MockOllaGovernance internal governance;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

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

        governance = new MockOllaGovernance();
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation),
            abi.encodeCall(WithdrawalQueue.initialize, (address(vault), address(governance), 80_000))
        );
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

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
    }

    /*//////////////////////////////////////////////////////////////
                         FINALIZE WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeWithdrawals_CompletesVaultPostProcessingWithinGasBudget() external {
        uint256 requestCount = 40;
        uint256 requestAssets = DECIMALS;

        for (uint256 i; i < requestCount; ++i) {
            address user = makeAddr(string.concat("user", vm.toString(i)));
            asset.mint(user, requestAssets);

            vm.prank(user);
            asset.approve(address(vault), requestAssets);

            vm.prank(user);
            uint256 shares = vault.deposit(requestAssets, user, 0);

            vm.prank(user);
            vault.requestRedeem(shares, user, user);
        }

        uint256 pendingBefore = vault.pendingWithdrawalAssets();

        vm.prank(address(core));
        (bool success,) = address(vault)
        .call{
            gas: 1_000_000
        }(abi.encodeCall(vault.finalizeWithdrawals, (pendingBefore, type(uint256).max, type(uint256).max)));

        assertTrue(success, "finalization should leave gas for vault post-processing");
        assertLt(vault.pendingWithdrawalAssets(), pendingBefore, "some withdrawals should finalize");
    }
}
