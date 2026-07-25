// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title Governance seams (fees-and-governance.md §1.4, §4)
/// @notice Minimal interfaces wiring StonkzFeeHook <-> CTOGovernor without circular imports.

/// @dev Checkpointed launch token read surface used by the CTO mechanism.
interface IVotesToken {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);
}

/// @dev CTO governor interlock queried by the hook before a voluntary transfer (§1.4).
interface ICTOGovernor {
    function ctoActive(address token) external view returns (bool);
}

/// @dev Receiver + token-page-admin registry (the hook). CTO finalize transfers both (§4.4).
interface IFeeReceiverRegistry {
    function feeReceiver(address token) external view returns (address);
    function pageAdmin(address token) external view returns (address);
    /// @notice CTO-only: on a passed vote, move feeReceiver + pageAdmin to the winner.
    function governorTransfer(address token, address newReceiver, address newAdmin) external;
}
