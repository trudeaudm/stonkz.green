// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "./TickMath.sol";

/// @title LiquidityAmounts — helpers for price-setting / single-sided ranges (spec §8.2)
library LiquidityAmounts {
    uint256 internal constant Q96 = 2 ** 96;

    /// @notice Liquidity for amounts around current sqrt price spanning [tickLower, tickUpper].
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            return getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtPriceX96 < sqrtRatioBX96) {
            uint128 liq0 = getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0);
            uint128 liq1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount1);
            return liq0 < liq1 ? liq0 : liq1;
        } else {
            return getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        uint256 intermediate = FixedPointMathLib.fullMulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        uint256 liq = FixedPointMathLib.fullMulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96);
        require(liq <= type(uint128).max, "liq");
        return uint128(liq);
    }

    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        uint256 liq = FixedPointMathLib.fullMulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96);
        require(liq <= type(uint128).max, "liq");
        return uint128(liq);
    }

    /// @notice Amounts for a single-sided token1 (above current) or token0 (below) range.
    function amountsForSingleSided(
        int24 tickLower,
        int24 tickUpper,
        uint256 amountTokens,
        bool tokensAreCurrency1
    ) internal pure returns (uint256 amount0, uint256 amount1, uint128 liquidity) {
        uint160 sa = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sb = TickMath.getSqrtRatioAtTick(tickUpper);
        if (tokensAreCurrency1) {
            // range entirely above current → only token1
            liquidity = getLiquidityForAmount1(sa, sb, amountTokens);
            amount1 = amountTokens;
            amount0 = 0;
        } else {
            liquidity = getLiquidityForAmount0(sa, sb, amountTokens);
            amount0 = amountTokens;
            amount1 = 0;
        }
    }
}
