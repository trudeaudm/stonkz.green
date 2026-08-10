// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title Vanity — 0x4663 prefix helpers (docs/03 VANITY PREFIX)
/// @notice Top two address bytes must equal 0x4663. Salt binding stays keccak256(deployer, userSalt).
library Vanity {
    /// @dev 0x4663 — Robinhood chain id / brand prefix.
    uint16 internal constant PREFIX = 0x4663;

    error VanityPrefixMismatch(address predicted);

    /// @notice Top two bytes of a 20-byte address (explorer truncation: 0x4663…).
    function prefixOf(address a) internal pure returns (uint16) {
        return uint16(uint160(a) >> 144);
    }

    function matches(address a) internal pure returns (bool) {
        return prefixOf(a) == PREFIX;
    }

    function requirePrefix(address predicted) internal pure {
        if (!matches(predicted)) revert VanityPrefixMismatch(predicted);
    }

    /// @notice CREATE2 predict: address(keccak256(0xff ++ deployer ++ salt ++ initCodeHash)).
    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Brute-force userSalt until predicted address matches PREFIX and is empty.
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
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            userSalt = bytes32(i);
            bytes32 salt = keccak256(abi.encode(caller, userSalt));
            predicted = predict(factory, salt, initCodeHash);
            if (matches(predicted) && predicted.code.length == 0) return (userSalt, predicted);
        }
        revert("Vanity: no salt in 1e6");
    }
}
