// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IMockAztecRollup } from "src/staking/mocks/IMockAztecRollup.sol";
import { BaseScript } from "../base/BaseScript.s.sol";

/// @title PrintState
/// @notice Prints OllaCore state (latestReport + accountingState) and key balances.
contract PrintState is BaseScript {
    function run() external view {
        string memory env = _deployEnv();

        address core = vm.envOr("CORE", address(0));
        if (core == address(0)) {
            core = _tryReadDeployment(env, "OllaCoreProxy");
        }
        require(core != address(0), "CORE missing: set CORE or deploy local");

        IOllaCore c = IOllaCore(core);

        address asset = c.asset();
        address rewardsVault = c.rewardsVault();
        address stAztec = c.stAztec();
        address stakingManager = c.stakingManager();
        address withdrawalQueue = c.withdrawalQueue();
        address governance = c.governance();

        console2.log("env", env);
        console2.log("core", core);
        console2.log("asset", asset);
        console2.log("stAztec", stAztec);
        console2.log("rewardsVault", rewardsVault);
        console2.log("withdrawalQueue", withdrawalQueue);
        console2.log("stakingManager", stakingManager);
        console2.log("governance", governance);

        console2.log("totalAssets()", c.totalAssets());
        console2.log("exchangeRate()", c.exchangeRate());

        IOllaCore.LatestReport memory r = c.latestReport();
        console2.log("latestReport.totalAssets", r.totalAssets);
        console2.log("latestReport.exchangeRate", r.exchangeRate);
        console2.log("latestReport.grossRewards", r.grossRewards);
        console2.log("latestReport.netFlows");
        console2.logInt(r.netFlows);
        console2.log("latestReport.rewardsSnapshot", r.rewardsSnapshot);
        console2.log("latestReport.timestamp", r.timestamp);

        IOllaCore.AccountingState memory a = c.accountingState();
        console2.log("accounting.bufferedAssets", a.bufferedAssets);
        console2.log("accounting.stakedPrincipal", a.stakedPrincipal);
        console2.log("accounting.rewardsVaultBalance", a.rewardsVaultBalance);
        console2.log("accounting.claimableRewards", a.claimableRewards);
        console2.log("accounting.rewardsDelta", a.rewardsDelta);
        console2.log("accounting.slashingDelta", a.slashingDelta);
        console2.log("accounting.cumulativeRewards", a.cumulativeRewards);

        IOllaCore.FlowCounters memory f = c.flowCounters();
        console2.log("flows.cumulativeDeposits", f.cumulativeDeposits);
        console2.log("flows.cumulativeWithdrawals", f.cumulativeWithdrawals);
        console2.log("flows.latestReportCumulativeDeposits", f.latestReportCumulativeDeposits);
        console2.log("flows.latestReportCumulativeWithdrawals", f.latestReportCumulativeWithdrawals);

        console2.log("asset.balance(core)", IERC20(asset).balanceOf(core));
        console2.log("asset.balance(rewardsVault)", IERC20(asset).balanceOf(rewardsVault));

        console2.log("stAztec.totalSupply", IERC20(stAztec).totalSupply());

        address rollup = _tryReadDeployment(env, "MockAztecRollup");
        if (rollup != address(0)) {
            console2.log("rollup", rollup);
            console2.log(
                "rollup.pendingRewards(rewardsVault)", IMockAztecRollup(rollup).getSequencerRewards(rewardsVault)
            );
        }
    }
}
