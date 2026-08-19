// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "@v4-core/src/libraries/Hooks.sol";

/// @title HookVanity — mine CREATE2 address: top 0x4663 + low flags 0x0CC
/// @notice Production target ~2^30: PREFIX (16 bits) + HOOK_FLAGS (14 bits of low address).
///         Salt binding for factory deploys stays keccak256(deployer, userSalt); EOA mode uses
///         userSalt directly as CREATE2 salt.
/// @dev Flags 0x0CC = BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
///      (docs/06 pair-side take: specified in beforeSwap, unspecified in afterSwap).
library HookVanity {
    /// @dev 0x4663 — Robinhood chain id / brand prefix.
    uint16 internal constant PREFIX = 0x4663;

    /// @dev BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    error HookVanityMismatch(address predicted);
    error HookVanityMineFailed();

    /// @notice Top two bytes of `a` (explorer truncation: 0x4663…).
    /// @param a Address to inspect.
    /// @return The 16-bit prefix.
    function prefixOf(address a) internal pure returns (uint16) {
        return uint16(uint160(a) >> 144);
    }

    /// @notice Low 14 bits of `a` (v4 hook permission flags).
    /// @param a Address to inspect.
    /// @return The flag bits (`Hooks.ALL_HOOK_MASK`).
    function flagsOf(address a) internal pure returns (uint160) {
        return uint160(a) & Hooks.ALL_HOOK_MASK;
    }

    /// @notice True iff `a` has prefix 0x4663 and flags `HOOK_FLAGS` (0x0CC).
    /// @param a Address to inspect.
    function matches(address a) internal pure returns (bool) {
        return prefixOf(a) == PREFIX && flagsOf(a) == HOOK_FLAGS;
    }

    /// @notice Revert `HookVanityMismatch` unless `predicted` matches prefix+flags.
    /// @param predicted CREATE2 predicted address.
    function requireMatch(address predicted) internal pure {
        if (!matches(predicted)) revert HookVanityMismatch(predicted);
    }

    /// @notice CREATE2 predict: address(keccak256(0xff ++ deployer ++ salt ++ initCodeHash)).
    /// @param deployer CREATE2 site (factory or Arachnid `CREATE2_FACTORY`).
    /// @param salt CREATE2 salt (factory mode: keccak256(caller, userSalt); EOA: userSalt).
    /// @param initCodeHash keccak256 of creation bytecode ‖ constructor args.
    /// @return Predicted deployment address.
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Brute-force userSalt until predicted address matches PREFIX+HOOK_FLAGS and is empty.
    /// @dev Resets free-memory pointer each iteration so long drills do not MemoryOOG.
    ///      ~2^30 expected; cap keeps CI bounded — production miner uses the JS script unbounded.
    /// @param factory CREATE2 deployer (our factory).
    /// @param caller Salt-binding address (`keccak256(caller, userSalt)`).
    /// @param initCodeHash keccak256 of creation bytecode ‖ constructor args.
    /// @return userSalt Winning salt half.
    /// @return predicted Matching empty address.
    function mine(address factory, address caller, bytes32 initCodeHash)
        internal
        view
        returns (bytes32 userSalt, address predicted)
    {
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
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
    /// @param deployer CREATE2 site (Foundry `CREATE2_FACTORY` for `new C{salt}`).
    /// @param initCodeHash keccak256 of creation bytecode ‖ constructor args.
    /// @return salt Winning CREATE2 salt.
    /// @return predicted Matching empty address.
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
