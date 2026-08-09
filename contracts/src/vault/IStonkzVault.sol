// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IStonkzVault — docs/10 gate + deposit surface
/// @notice The auction/factory gate reads exactly `lockedBalance` (docs/10 §6).
interface IStonkzVault {
    /// @notice Custody minus pending + matured-unexecuted direct-release amounts.
    ///         Path-pending still counts as locked. docs/10 §6.
    function lockedBalance(address token) external view returns (uint256);

    /// @notice Pull `amount` of `token` from caller; credit `beneficiary` (settlement + voluntary).
    function deposit(address token, uint256 amount, address beneficiary) external;
}
