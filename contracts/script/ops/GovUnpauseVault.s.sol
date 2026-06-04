// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { console2 } from "@forge-std/console2.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { OllaGovernance } from "src/governance/OllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { GovActionBase } from "./GovActionBase.s.sol";

/// @title GovUnpauseVault
/// @notice Schedules and executes OllaVault.unpause() via OllaGovernance timelock.
contract GovUnpauseVault is GovActionBase {
    uint256 internal constant _DEFAULT_REBALANCE_COOLDOWN = 86400;

    function run() external {
        address governance = _governanceAddress();
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        uint256 desiredCooldown = vm.envOr("REBALANCE_COOLDOWN", _DEFAULT_REBALANCE_COOLDOWN);

        console2.log("governance", governance);
        console2.log("vault", vault);
        console2.log("vault.paused(before)", OllaVault(vault).paused());
        console2.log("core.rebalanceCooldown(current)", OllaCore(core).rebalanceCooldown());
        console2.log("core.rebalanceCooldown(desired)", desiredCooldown);

        // Canonical activation chain runs setRebalanceCooldown before unpauseVault. The default
        // predecessor below ties unpauseVault behind that cooldown op while the live cooldown still
        // differs, so the timelock execute reverts rather than unpausing the vault at the stale 1h cadence.
        if (OllaCore(core).rebalanceCooldown() != desiredCooldown) {
            console2.log(
                "WARNING: rebalanceCooldown not yet at desired value; run GovSetRebalanceCooldown"
                " (REBALANCE_COOLDOWN) before unpausing the vault."
            );
        }

        if (!OllaVault(vault).paused()) {
            console2.log("OllaVault already unpaused");
            return;
        }

        bytes memory data = abi.encodeCall(OllaVault.unpause, ());
        _runTimelockAction(governance, vault, data);

        console2.log("vault.paused(after)", OllaVault(vault).paused());
    }

    function _defaultPredecessor(OllaGovernance governance, address, bytes memory)
        internal
        view
        override
        returns (bytes32)
    {
        address core = _addrOrDeployment("CORE", "OllaCoreProxy", "CORE missing");
        address vault = _addrOrDeployment("VAULT", "OllaVaultProxy", "VAULT missing");

        bytes memory setVaultData = abi.encodeCall(OllaCore.setVault, (vault));
        bytes32 setVaultOpId = governance.hashOperation(core, 0, setVaultData, bytes32(0), _salt());

        bytes memory unpauseCoreData = abi.encodeCall(OllaCore.unpause, ());
        bytes32 unpauseCoreOpId = governance.hashOperation(core, 0, unpauseCoreData, setVaultOpId, _salt());

        uint256 desiredCooldown = vm.envOr("REBALANCE_COOLDOWN", _DEFAULT_REBALANCE_COOLDOWN);
        bytes memory setCooldownData = abi.encodeCall(OllaCore.setRebalanceCooldown, (desiredCooldown));
        bytes32 setCooldownOpId = governance.hashOperation(core, 0, setCooldownData, unpauseCoreOpId, _salt());

        // While the live cooldown differs from the target, require the cooldown op as the predecessor so
        // the vault cannot be unpaused before the intended 24h cadence is set.
        if (OllaCore(core).rebalanceCooldown() != desiredCooldown) {
            return setCooldownOpId;
        }

        // Cooldown already at target: keep the cooldown op as predecessor if it was actually executed;
        // otherwise (e.g. cooldown set by a direct owner call) fall back to the reachable unpauseCore op.
        if (governance.isOperationDone(setCooldownOpId)) {
            return setCooldownOpId;
        }
        return unpauseCoreOpId;
    }
}
