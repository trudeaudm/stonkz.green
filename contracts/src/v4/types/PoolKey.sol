// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "./Currency.sol";

/// @notice Uniswap v4 PoolKey shape (spec §8 settlement venue).
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev keccak256 of abi.encode(key) — PoolId as bytes32.
type PoolId is bytes32;

library PoolIdLibrary {
    function toId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}
