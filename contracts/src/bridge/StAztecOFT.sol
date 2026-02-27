// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { OFT } from "@lz-oft/contracts/OFT.sol";
import { Ownable } from "@oz/access/Ownable.sol";

/// @title StAztecOFT
/// @notice Bridged representation of stAztec on destination chains, using LayerZero V2
///         OFT (burn/mint) model.
/// @dev Mints tokens when stAztec is bridged from the home chain and burns them when
///      sent back. The `_delegate` (owner) should be set to the OllaGovernance
///      TimelockController in production to control peer configuration and DVN settings.
/// @author Olla Core contributors
contract StAztecOFT is OFT {
    /// @notice Deploys the bridged stAztec token on a destination chain.
    /// @param _name       Token name (e.g. "stAztec").
    /// @param _symbol     Token symbol (e.g. "stAZTEC").
    /// @param _lzEndpoint Address of the LayerZero V2 endpoint on this chain.
    /// @param _delegate   Address that will own this OApp and control peer/DVN config
    ///                    (OllaGovernance TimelockController in production).
    constructor(string memory _name, string memory _symbol, address _lzEndpoint, address _delegate)
        OFT(_name, _symbol, _lzEndpoint, _delegate)
        Ownable(_delegate)
    { }
}
