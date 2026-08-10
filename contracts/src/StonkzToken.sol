// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title StonkzToken - protocol $STONKZ4663 (docs/03 ONE DEPLOY)
/// @notice Fixed supply 100_000_000 x 1e18. Minted once at construction to custody.
///         No mint function. Zero approvals at birth. No pools created by this contract.
/// @dev Separate from StonkzLaunchToken (per-launch checkpointed ERC20). This is the
///      protocol token parked until genesis; side pools pair against this address.
contract StonkzToken is ERC20 {
    /// @dev 100,000,000 whole tokens x 1e18 wei. Unit: wei.
    uint256 public constant TOTAL_SUPPLY = 100_000_000 ether; // 1e8 * 1e18

    string private constant _NAME = "STONKZ";
    string private constant _SYMBOL = "STONKZ4663";

    /// @notice Custody that received the entire genesis mint (transparency).
    address public immutable custody;

    error ZeroCustody();

    /// @param custody_ David-supplied custody address (runbook input). Receives full supply.
    constructor(address custody_) {
        if (custody_ == address(0)) revert ZeroCustody();
        custody = custody_;
        _mint(custody_, TOTAL_SUPPLY);
    }

    function name() public pure override returns (string memory) {
        return _NAME;
    }

    function symbol() public pure override returns (string memory) {
        return _SYMBOL;
    }
}
