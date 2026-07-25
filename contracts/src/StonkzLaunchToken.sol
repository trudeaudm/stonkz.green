// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title StonkzLaunchToken — checkpointed launch token (fees-and-governance.md §3, spec §8.9)
/// @notice ERC20 with per-account BALANCE checkpoints (ERC20Votes-style, no delegation).
///         Voting reads use past-block snapshots so CTO power is flashloan-immune
///         (§4.2: `power = min(balance @ snapshot, balance @ vote)`).
/// @dev We deliberately checkpoint raw balances rather than delegated votes:
///      the CTO mechanism (fees-and-governance.md §4) grants power by holdings,
///      not by an opt-in delegation step. Solady `ERC20Votes` was evaluated but its
///      delegation model would zero-out every non-self-delegating holder — the wrong
///      default for a launchpad token. Checkpoints written in `_afterTokenTransfer`.
///      Mint happens ONCE, at construction, to the factory/listing/auction manager.
contract StonkzLaunchToken is ERC20 {
    struct Checkpoint {
        uint48 fromBlock;
        uint208 balance;
    }

    string private _name;
    string private _symbol;

    /// @dev Per-account ascending-by-block balance history.
    mapping(address => Checkpoint[]) private _checkpoints;

    /// @notice The one address allowed to have received the genesis mint (transparency).
    address public immutable minter;

    error FutureLookup();

    constructor(string memory name_, string memory symbol_, uint256 supply_, address mintTo_) {
        _name = name_;
        _symbol = symbol_;
        minter = mintTo_;
        _mint(mintTo_, supply_);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Balance of `account` as of the end of `blockNumber` (fees-and-governance.md §4.2).
    /// @dev Strictly-past lookup (flashloan-immune): `blockNumber` must be < current block.
    function getPastVotes(address account, uint256 blockNumber) public view returns (uint256) {
        if (blockNumber >= block.number) revert FutureLookup();
        return _checkpointLookup(_checkpoints[account], blockNumber);
    }

    /// @notice Number of checkpoints recorded for `account` (test / introspection).
    function numCheckpoints(address account) external view returns (uint256) {
        return _checkpoints[account].length;
    }

    /// @dev Binary search: highest checkpoint with fromBlock <= blockNumber.
    function _checkpointLookup(Checkpoint[] storage ckpts, uint256 blockNumber)
        internal
        view
        returns (uint256)
    {
        uint256 len = ckpts.length;
        if (len == 0) return 0;
        // If the earliest checkpoint is already after the query, the account held 0.
        if (ckpts[0].fromBlock > blockNumber) return 0;
        uint256 lo = 0;
        uint256 hi = len; // exclusive
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (ckpts[mid].fromBlock <= blockNumber) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // lo is first index with fromBlock > blockNumber; answer is lo-1.
        return ckpts[lo - 1].balance;
    }

    /// @dev ERC20 post-transfer hook: write balance checkpoints for both parties.
    function _afterTokenTransfer(address from, address to, uint256) internal override {
        if (from != address(0)) _writeCheckpoint(from);
        if (to != address(0)) _writeCheckpoint(to);
    }

    function _writeCheckpoint(address account) internal {
        uint256 bal = balanceOf(account);
        require(bal <= type(uint208).max, "ckpt overflow");
        Checkpoint[] storage ckpts = _checkpoints[account];
        uint256 len = ckpts.length;
        uint48 blk = uint48(block.number);
        if (len > 0 && ckpts[len - 1].fromBlock == blk) {
            ckpts[len - 1].balance = uint208(bal);
        } else {
            ckpts.push(Checkpoint({fromBlock: blk, balance: uint208(bal)}));
        }
    }
}
