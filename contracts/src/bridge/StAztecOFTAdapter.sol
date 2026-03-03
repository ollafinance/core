// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { OFTAdapter } from "@lz-oft/contracts/OFTAdapter.sol";
import { Ownable } from "@oz/access/Ownable.sol";

/// @title StAztecOFTAdapter
/// @notice OFTAdapter that locks/unlocks stAztec on the home chain (Ethereum) for
///         cross-chain bridging via LayerZero V2.
/// @dev Only ONE adapter must exist per global OFT mesh. The adapter holds locked
///      stAztec tokens while bridged representations are minted on destination chains.
///      The `_delegate` (owner) should be set to the OllaGovernance TimelockController
///      in production to control peer configuration and DVN settings.
/// @author Olla Core contributors
contract StAztecOFTAdapter is OFTAdapter {
    /// @notice Deploys the adapter for the stAztec token.
    /// @param _stAztec  Address of the stAztec ERC-20 token on the home chain.
    /// @param _lzEndpoint Address of the LayerZero V2 endpoint on this chain.
    /// @param _delegate   Address that will own this OApp and control peer/DVN config
    ///                    (OllaGovernance TimelockController in production).
    constructor(address _stAztec, address _lzEndpoint, address _delegate)
        OFTAdapter(_stAztec, _lzEndpoint, _delegate)
        Ownable(_delegate)
    { }
}
