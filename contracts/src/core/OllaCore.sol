// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@oz/utils/math/Math.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";
import { IOllaCore } from "src/interfaces/IOllaCore.sol";
import { IStAztec } from "src/interfaces/IStAztec.sol";

/// @title OllaCore
/// @notice Core vault handling deposits and async withdrawals.
/// @author Olla Core contributors
contract OllaCore is Initializable, IOllaCore, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 private constant _EXCHANGE_RATE_SCALE = 1e18;

    IERC20 private _asset;
    IStAztec private _stAztec;
    uint256 private _unusedReentrancyStatus;

    mapping(address owner => PendingWithdrawal withdrawal) private _pendingWithdrawals;

    /// @notice Thrown when a pending withdrawal already exists.
    error OllaCorePendingWithdrawalExists(address owner);

    /// @notice Thrown when no pending withdrawal exists.
    error OllaCoreNoPendingWithdrawal(address owner);

    /// @notice Thrown when a zero address is provided.
    error OllaCoreZeroAddress();

    /// @notice Thrown when assets are unavailable for claiming.
    error OllaCoreInsufficientLiquidity(uint256 assets, uint256 available);

    /// @notice Thrown when a caller is not the share owner.
    error OllaCoreUnauthorized(address caller, address owner);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vault with asset and stAztec addresses.
    /// @param asset_ The underlying Aztec asset.
    /// @param stAztec_ The stAztec share token.
    function initialize(IERC20 asset_, IStAztec stAztec_) external override initializer {
        if (address(asset_) == address(0) || address(stAztec_) == address(0)) {
            revert OllaCoreZeroAddress();
        }

        _asset = asset_;
        _stAztec = stAztec_;
        _unusedReentrancyStatus = 0;
    }

    /// @notice Deposits assets and mints stAztec shares.
    /// @param assets The amount of assets to deposit.
    /// @param receiver The recipient of the stAztec shares.
    /// @return shares The shares minted to the receiver.
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) {
            revert OllaCoreZeroAddress();
        }

        shares = _convertToSharesForDeposit(assets);
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _stAztec.mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /// @notice Requests a redemption in shares.
    /// @param shares The number of shares to redeem.
    /// @param receiver The receiver of the assets.
    /// @param owner The owner of the shares.
    /// @return assets The assets expected from the redemption.
    function requestRedeem(uint256 shares, address receiver, address owner)
        external
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = _convertToAssetsForRedeem(shares);
        _requestWithdrawal(shares, assets, receiver, owner);
        emit RequestRedeem(owner, receiver, assets, shares);
        return assets;
    }

    /// @notice Claims a pending withdrawal for an owner.
    /// @param owner The owner of the pending withdrawal.
    /// @return assets The assets transferred to the receiver.
    function claimPendingWithdraw(address owner) external override nonReentrant returns (uint256 assets) {
        PendingWithdrawal memory pending = _pendingWithdrawals[owner];
        if (pending.shares == 0) {
            revert OllaCoreNoPendingWithdrawal(owner);
        }

        uint256 availableAssets = totalAssets();
        if (pending.assets > availableAssets) {
            revert OllaCoreInsufficientLiquidity(pending.assets, availableAssets);
        }

        assets = pending.assets;
        _clearPendingWithdrawal(owner);
        _asset.safeTransfer(pending.receiver, assets);
        emit Withdraw(msg.sender, pending.receiver, owner, assets, pending.shares);

        emit ClaimRedeem(owner, pending.receiver, assets, pending.shares);
        return assets;
    }

    /// @notice Returns the underlying asset address.
    /// @return The underlying asset address.
    function asset() external view override returns (address) {
        return address(_asset);
    }

    /// @notice Returns the stAztec share token address.
    /// @return The stAztec share token address.
    function stAztec() external view override returns (address) {
        return address(_stAztec);
    }

    /// @notice Returns the current exchange rate in 18-decimal fixed-point units.
    /// @return The exchange rate scaled by 1e18.
    function exchangeRate() external view override returns (uint256) {
        IStAztec stAztecToken = _stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return _EXCHANGE_RATE_SCALE;
        }
        return (totalAssets() * _EXCHANGE_RATE_SCALE) / supply;
    }

    /// @notice Returns the pending withdrawal for an owner.
    /// @param owner The owner to query.
    /// @return The pending withdrawal details.
    function pendingWithdrawal(address owner) external view override returns (PendingWithdrawal memory) {
        return _pendingWithdrawals[owner];
    }

    /// @notice Returns the current total assets held by the vault.
    /// @return The total assets held by the vault.
    function totalAssets() public view override returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function _requestWithdrawal(uint256 shares, uint256 assets, address receiver, address owner) internal {
        if (receiver == address(0) || owner == address(0)) {
            revert OllaCoreZeroAddress();
        }

        if (_pendingWithdrawals[owner].shares != 0) {
            revert OllaCorePendingWithdrawalExists(owner);
        }

        if (msg.sender != owner) {
            revert OllaCoreUnauthorized(msg.sender, owner);
        }

        uint256 availableAssets = totalAssets();
        if (assets > availableAssets) {
            revert OllaCoreInsufficientLiquidity(assets, availableAssets);
        }

        _pendingWithdrawals[owner] = PendingWithdrawal({ shares: shares, assets: assets, receiver: receiver });

        _stAztec.burn(owner, shares);
    }

    function _clearPendingWithdrawal(address owner) internal {
        delete _pendingWithdrawals[owner];
    }

    function _convertToSharesForDeposit(uint256 assets) internal view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        IStAztec stAztecToken = _stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return assets;
        }
        return assets.mulDiv(supply, totalAssets(), rounding);
    }

    function _convertToAssetsForRedeem(uint256 assets) internal view returns (uint256) {
        return _convertToAssets(assets, Math.Rounding.Ceil);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        IStAztec stAztecToken = _stAztec;
        uint256 supply = stAztecToken.totalSupply();
        if (supply == 0) {
            return shares;
        }
        return shares.mulDiv(totalAssets(), supply, rounding);
    }
}
