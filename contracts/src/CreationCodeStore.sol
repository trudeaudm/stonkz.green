// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {SSTORE2} from "solady/utils/SSTORE2.sol";

/// @title CreationCodeStore — SSTORE2-backed creation bytecode (EIP-170 factory slim)
/// @notice Factories must not embed `type(C).creationCode` when C's initcode is large;
///         that bloats factory runtime past 24,576. Store creation bytes off-factory via
///         SSTORE2; CREATE2 still uses keccak256(creation ‖ args) so vanity is unchanged.
/// @dev DirectListing creation (~29KB) needs two chunks; LadderAuction (~21KB) fits one.
library CreationCodeStore {
    /// @dev EIP-170 max runtime minus SSTORE2's leading STOP byte.
    uint256 internal constant MAX_CHUNK = 24_575;

    error EmptyCreationCode();
    error CreationCodeTooLarge();
    error CreationCodePointerMissing();

    /// @notice Write `data` to one or two SSTORE2 pointers (second is address(0) if unneeded).
    function writeSplit(bytes memory data) internal returns (address ptr0, address ptr1) {
        uint256 n = data.length;
        if (n == 0) revert EmptyCreationCode();
        if (n <= MAX_CHUNK) {
            return (SSTORE2.write(data), address(0));
        }
        if (n > MAX_CHUNK * 2) revert CreationCodeTooLarge();
        uint256 mid = n - MAX_CHUNK; // tail saturates MAX_CHUNK; head is the remainder
        if (mid > MAX_CHUNK) mid = MAX_CHUNK;
        ptr0 = SSTORE2.write(_slice(data, 0, mid));
        ptr1 = SSTORE2.write(_slice(data, mid, n - mid));
    }

    /// @notice Reassemble creation bytecode from one or two SSTORE2 pointers.
    function readSplit(address ptr0, address ptr1) internal view returns (bytes memory data) {
        if (ptr0 == address(0)) revert CreationCodePointerMissing();
        data = SSTORE2.read(ptr0);
        if (ptr1 != address(0)) {
            data = bytes.concat(data, SSTORE2.read(ptr1));
        }
    }

    /// @notice CREATE2 deploy: initcode = creation ‖ args. Returns deployed address (or 0).
    function create2(address ptr0, address ptr1, bytes memory args, bytes32 salt, uint256 value)
        internal
        returns (address deployed)
    {
        bytes memory initCode = bytes.concat(readSplit(ptr0, ptr1), args);
        assembly ("memory-safe") {
            deployed := create2(value, add(initCode, 0x20), mload(initCode), salt)
        }
    }

    /// @notice CREATE deploy (no salt): initcode = creation ‖ args.
    function create(address ptr0, address ptr1, bytes memory args, uint256 value)
        internal
        returns (address deployed)
    {
        bytes memory initCode = bytes.concat(readSplit(ptr0, ptr1), args);
        assembly ("memory-safe") {
            deployed := create(value, add(initCode, 0x20), mload(initCode))
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        assembly ("memory-safe") {
            let src := add(add(data, 0x20), start)
            let dst := add(out, 0x20)
            let end := add(src, len)
            for {} lt(src, end) {} {
                mstore(dst, mload(src))
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            }
        }
    }
}
