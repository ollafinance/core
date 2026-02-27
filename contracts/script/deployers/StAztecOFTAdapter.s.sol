// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { StAztecOFTAdapter } from "src/bridge/StAztecOFTAdapter.sol";
import { BaseDeployer } from "./../base/BaseDeployer.s.sol";
import { DeployConfig } from "./../config/Config.s.sol";

/// @title StAztecOFTAdapterDeployer
/// @notice Deploys StAztecOFTAdapter (LayerZero V2 lock/unlock bridge on the home chain)
contract StAztecOFTAdapterDeployer is BaseDeployer {
    /// @notice Deploy StAztecOFTAdapter
    /// @param config The deployment configuration
    /// @param stAztec The stAztec token address
    /// @param lzEndpoint The LayerZero V2 endpoint address
    /// @param delegate The owner/delegate for OApp peer and DVN config (OllaGovernance in production)
    /// @return adapter The deployed StAztecOFTAdapter address
    function deploy(DeployConfig memory config, address stAztec, address lzEndpoint, address delegate)
        external
        returns (address adapter)
    {
        require(stAztec != address(0), "StAztecOFTAdapterDeployer: stAztec address required");
        require(lzEndpoint != address(0), "StAztecOFTAdapterDeployer: lzEndpoint address required");
        require(delegate != address(0), "StAztecOFTAdapterDeployer: delegate address required");

        vm.startBroadcast(config.deployerPrivateKey);

        StAztecOFTAdapter deployed = new StAztecOFTAdapter(stAztec, lzEndpoint, delegate);
        _logDeployment("StAztecOFTAdapter", address(deployed));

        vm.stopBroadcast();

        return address(deployed);
    }
}
