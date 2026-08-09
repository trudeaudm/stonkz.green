// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IReleasePath — marker for registered vault release paths (docs/10 §4)
/// @notice Paths are contracts, not EOAs. First-party paths (airdropper, emissions) are
///         NOT built in this chain — registry is present and mock-tested only.
interface IReleasePath {
    /// @notice Called when the vault completes a path transfer into this contract.
    function onVaultPathReceive(address token, uint256 amount, address from) external;
}
