// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

contract WithdrawalQueueGasTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant _DEPOSIT_ASSETS = 1;
    uint256 private constant _REQUEST_SHARES = 1;
    uint256 private constant _REQUEST_ASSETS_EXPECTED = 1;
    uint256 private constant _REQUEST_RATE = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct System {
        MockAztec asset;
        OllaCore vault;
        StAztec stAztec;
        MockAccountingStakingManager stakingManager;
        WithdrawalQueue queue;
        MockRewardsVault rewardsVault;
        MockSafetyModule safetyModule;
        address governance;
        address operator;
    }

    /*//////////////////////////////////////////////////////////////
                              CORE GAS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RebalanceGas_GrowsWithQueuedWithdrawalCount() external {
        uint256 n1 = 25;
        uint256 n2 = 100;
        uint256 n3 = 300;

        uint256 gas1 = _gasForRebalanceWithNRequests(n1);
        uint256 gas2 = _gasForRebalanceWithNRequests(n2);
        uint256 gas3 = _gasForRebalanceWithNRequests(n3);

        emit log_named_uint("rebalanceGas n=25", gas1);
        emit log_named_uint("rebalanceGas n=100", gas2);
        emit log_named_uint("rebalanceGas n=300", gas3);

        assertLt(gas1, gas2, "rebalance gas should increase with more withdrawals");
        assertLt(gas2, gas3, "rebalance gas should increase with more withdrawals");

        uint256 slope12 = (gas2 - gas1) / (n2 - n1);
        uint256 slope23 = (gas3 - gas2) / (n3 - n2);
        emit log_named_uint("rebalanceGasPerWithdrawal (25->100)", slope12);
        emit log_named_uint("rebalanceGasPerWithdrawal (100->300)", slope23);
        assertGt(slope12, 0, "marginal gas per request must be > 0");
        assertGt(slope23, 0, "marginal gas per request must be > 0");
    }

    function test_QueueFinalizeGas_GrowsWithQueuedWithdrawalCount() external {
        uint256 n1 = 50;
        uint256 n2 = 200;

        uint256 gas1 = _gasForQueueFinalizeWithNRequests(n1);
        uint256 gas2 = _gasForQueueFinalizeWithNRequests(n2);

        emit log_named_uint("queueFinalizeGas n=50", gas1);
        emit log_named_uint("queueFinalizeGas n=200", gas2);

        assertLt(gas1, gas2, "finalize gas should increase with more queued requests");
        uint256 slope = (gas2 - gas1) / (n2 - n1);
        emit log_named_uint("queueFinalizeGasPerWithdrawal (50->200)", slope);
        assertGt(slope, 0, "marginal gas per request must be > 0");
    }

    function test_Rebalance_CanBeForcedToExceedFixedGasBudget() external {
        uint256 nSmall = 25;
        uint256 nLarge = 400;

        // Measure gas requirements (normal calls).
        uint256 gasSmall = _gasForRebalanceWithNRequests(nSmall);
        uint256 gasLarge = _gasForRebalanceWithNRequests(nLarge);

        emit log_named_uint("measured rebalanceGas n=25", gasSmall);
        emit log_named_uint("measured rebalanceGas n=400", gasLarge);

        assertGt(gasLarge, gasSmall, "rebalance must cost more with more withdrawals");

        // Choose a fixed gas budget between the two measurements.
        uint256 gasBudget = gasSmall + (gasLarge - gasSmall) / 2;
        emit log_named_uint("chosen gasBudget", gasBudget);

        // Demonstrate: small succeeds under the budget, large fails under the same budget.
        System memory sSmall = _deploySystem();
        _enqueueNWithdrawals(sSmall, nSmall);

        vm.prank(sSmall.operator);
        (bool okSmall,) = address(sSmall.vault).call{ gas: gasBudget }(abi.encodeCall(OllaCore.rebalance, ()));
        assertTrue(okSmall, "small queue should rebalance within fixed gas budget");

        System memory sLarge = _deploySystem();
        _enqueueNWithdrawals(sLarge, nLarge);

        vm.prank(sLarge.operator);
        (bool okLarge,) = address(sLarge.vault).call{ gas: gasBudget }(abi.encodeCall(OllaCore.rebalance, ()));
        assertFalse(okLarge, "large queue should exceed the same fixed gas budget");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _gasForRebalanceWithNRequests(uint256 n) internal returns (uint256 gasUsed) {
        System memory s = _deploySystem();
        _enqueueNWithdrawals(s, n);

        uint256 gasBefore = gasleft();
        vm.prank(s.operator);
        s.vault.rebalance();
        gasUsed = gasBefore - gasleft();
        return gasUsed;
    }

    function _gasForQueueFinalizeWithNRequests(uint256 n) internal returns (uint256 gasUsed) {
        address core = address(this);
        address admin = makeAddr("admin");

        WithdrawalQueue implementation = new WithdrawalQueue();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(WithdrawalQueue.initialize, (core, admin)));
        WithdrawalQueue queue = WithdrawalQueue(address(proxy));

        for (uint256 i = 0; i < n; ++i) {
            address user = address(uint160(10_000 + i));
            vm.prank(core);
            queue.requestWithdrawal(user, _REQUEST_SHARES, _REQUEST_ASSETS_EXPECTED, _REQUEST_RATE);
        }

        uint256 gasBefore = gasleft();
        vm.prank(core);
        queue.finalizeWithdrawals(n);
        gasUsed = gasBefore - gasleft();
        return gasUsed;
    }

    function _deploySystem() internal returns (System memory s) {
        s.asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        s.vault = OllaCore(address(coreProxy));

        s.governance = makeAddr("governance");
        s.operator = makeAddr("operator");
        s.stAztec = new StAztec(s.governance, address(s.vault));
        s.stakingManager = new MockAccountingStakingManager();

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(
            address(queueImplementation), abi.encodeCall(WithdrawalQueue.initialize, (address(s.vault), s.governance))
        );
        s.queue = WithdrawalQueue(address(queueProxy));

        s.rewardsVault = new MockRewardsVault(s.asset, address(s.vault));
        s.safetyModule = new MockSafetyModule(address(s.vault));

        s.stakingManager.setRewardsToken(s.asset);
        s.stakingManager.setRewardsVault(address(s.rewardsVault));

        s.vault
            .initialize(
                s.asset,
                s.stAztec,
                s.stakingManager,
                0,
                0,
                s.governance,
                address(s.queue),
                s.rewardsVault,
                address(s.safetyModule)
            );

        bytes32 operatorRole = s.vault.OPERATOR_ROLE();
        vm.prank(s.governance);
        s.vault.grantRole(operatorRole, s.operator);
        return s;
    }

    function _enqueueNWithdrawals(System memory s, uint256 n) internal {
        for (uint256 i = 0; i < n; ++i) {
            address user = address(uint160(20_000 + i));

            s.asset.mint(user, _DEPOSIT_ASSETS);
            vm.startPrank(user);
            s.asset.approve(address(s.vault), _DEPOSIT_ASSETS);
            s.vault.deposit(_DEPOSIT_ASSETS, user);
            s.vault.requestRedeem(_REQUEST_SHARES, user);
            vm.stopPrank();
        }
    }
}
