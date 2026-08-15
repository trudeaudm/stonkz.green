// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";

/// @dev Minimal extsload mock for DeployControls.currentEthUsdWad unit tests.
contract MockExtsloadPM {
    mapping(bytes32 => bytes32) internal _slots;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function setSlot(bytes32 slot, bytes32 value) external {
        _slots[slot] = value;
    }
}

/// @title EthUsdRefHelpers — wire mock two-pool ETH/USD refs for Express list() stamps
library EthUsdRefHelpers {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    bytes32 internal constant PRIMARY_ID = bytes32(uint256(0xB01));
    bytes32 internal constant CHECK_ID = bytes32(uint256(0xA01));

    function stateSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    function liquiditySlot(bytes32 poolId) internal pure returns (bytes32) {
        return bytes32(uint256(stateSlot(poolId)) + LIQUIDITY_OFFSET);
    }

    /// @dev sqrtPriceX96 such that ethIs0 + stableDec=6 ⇒ currentEthUsdWad ≈ ethUsdWad.
    function sqrtPriceX96ForEthUsd(uint256 ethUsdWad) internal pure returns (uint160) {
        // ethUsdWad = sqrtP² * 1e30 / 2^192  ⇒  sqrtP² = ethUsdWad * 2^192 / 1e30
        uint256 ratioX192 = FixedPointMathLib.fullMulDiv(ethUsdWad, uint256(1) << 192, 1e30);
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }

    function packSlot0(uint160 sqrtPriceX96) internal pure returns (bytes32) {
        return bytes32(uint256(sqrtPriceX96));
    }

    function etchPool(
        MockExtsloadPM pm,
        bytes32 poolId,
        uint160 sqrtPriceX96,
        uint128 liquidity
    ) internal {
        pm.setSlot(stateSlot(poolId), packSlot0(sqrtPriceX96));
        pm.setSlot(liquiditySlot(poolId), bytes32(uint256(liquidity)));
    }

    /// @notice Owner-wires factory to a fresh mock PM with primary≈check at `ethUsdWad`.
    function wireExpressRef(StonkzExpressFactory factory, uint256 ethUsdWad) internal returns (MockExtsloadPM pm) {
        pm = new MockExtsloadPM();
        uint160 sqrtP = sqrtPriceX96ForEthUsd(ethUsdWad);
        // Check pool: tiny +0.01% via slightly higher ethUsd (still within 5% default).
        uint160 sqrtCheck = sqrtPriceX96ForEthUsd(ethUsdWad + ethUsdWad / 10_000);
        etchPool(pm, PRIMARY_ID, sqrtP, 1e18);
        etchPool(pm, CHECK_ID, sqrtCheck, 1e18);
        factory.setRefPools(address(pm), PRIMARY_ID, true, 6, CHECK_ID, true, 6);
    }
}
