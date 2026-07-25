// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @dev Packed int128 amount0 | int128 amount1 (Uniswap v4 shape).
type BalanceDelta is int256;

using BalanceDeltaLibrary for BalanceDelta global;

library BalanceDeltaLibrary {
    function amount0(BalanceDelta d) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(d) >> 128));
    }

    function amount1(BalanceDelta d) internal pure returns (int128) {
        return int128(int256(BalanceDelta.unwrap(d)));
    }

    function from(int128 a0, int128 a1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap((int256(a0) << 128) | (int256(uint256(uint128(a1)))));
    }

    function zero() internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }
}
