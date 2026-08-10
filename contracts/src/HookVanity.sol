// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "@v4-core/src/libraries/Hooks.sol";

/// @title HookVanity — mine CREATE2 address: top 0x4663 + low flags 0x088 (V4-CANON Phase 1)
/// @notice Production target ~2^30: PREFIX (16 bits) + HOOK_FLAGS (14 bits of low address).
///         Salt binding for factory deploys stays keccak256(deployer, userSalt); EOA mode uses
///         userSalt directly as CREATE2 salt.
library HookVanity {
    /// @dev 0x4663 — Robinhood chain id / brand prefix.
    uint16 internal constant PREFIX = 0x4663;

    /// @dev BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA.
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    error HookVanityMismatch(address predicted);
    error HookVanityMineFailed();

    function prefixOf(address a) internal pure returns (uint16) {
        return uint16(uint160(a) >> 144);
    }

    function flagsOf(address a) internal pure returns (uint160) {
        return uint160(a) & Hooks.ALL_HOOK_MASK;
    }

    function matches(address a) internal pure returns (bool) {
        return prefixOf(a) == PREFIX && flagsOf(a) == HOOK_FLAGS;
    }

    function requireMatch(address predicted) internal pure {
        if (!matches(predicted)) revert HookVanityMismatch(predicted);
    }

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Brute-force userSalt until predicted address matches PREFIX+HOOK_FLAGS and is empty.
    /// @dev Resets free-memory pointer each iteration so long drills do not MemoryOOG.
    function mine(address factory, address caller, bytes32 initCodeHash)
        internal
        view
        returns (bytes32 userSalt, address predicted)
    {
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        // ~2^30 expected; cap keeps CI bounded — production miner uses the JS script unbounded.
        for (uint256 i; i < 50_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            userSalt = bytes32(i);
            bytes32 salt = keccak256(abi.encode(caller, userSalt));
            predicted = predict(factory, salt, initCodeHash);
            if (matches(predicted) && predicted.code.length == 0) return (userSalt, predicted);
        }
        revert HookVanityMineFailed();
    }

    /// @notice EOA CREATE2 mine (salt = userSalt directly).
    function mineEoa(address deployer, bytes32 initCodeHash)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        for (uint256 i; i < 50_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            salt = bytes32(i);
            predicted = predict(deployer, salt, initCodeHash);
            if (matches(predicted) && predicted.code.length == 0) return (salt, predicted);
        }
        revert HookVanityMineFailed();
    }
}
