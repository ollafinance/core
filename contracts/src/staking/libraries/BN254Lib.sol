// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

/// @title BN254Lib
/// @notice BLS key structures for BN254 curve, compatible with Aztec protocol.
/// @dev These types mirror the Aztec contracts for interoperability.
/// @author Olla Core contributors

/// @notice A point on the G1 curve.
/// @param x The x coordinate.
/// @param y The y coordinate.
struct G1Point {
    uint256 x;
    uint256 y;
}

/// @notice A point on the G2 curve.
/// @param x0 The x0 coordinate (imaginary part).
/// @param x1 The x1 coordinate (real part).
/// @param y0 The y0 coordinate (imaginary part).
/// @param y1 The y1 coordinate (real part).
struct G2Point {
    uint256 x0;
    uint256 x1;
    uint256 y0;
    uint256 y1;
}
