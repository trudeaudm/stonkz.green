// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "./v4/TickMath.sol";

/// @title SqrtPriceLib — WAD human price → Uniswap v4 `sqrtPriceX96`
/// @notice Single implementation for Express (`StonkzDirectListing`) and
///         `LadderSettlement`. Decimals-aware without pre-sqrt truncation.
///
/// @dev **Units.** `priceWad` is a human token1/token0 ratio in WAD
///      (`human * 1e18`), after the caller’s optional invert when the priced
///      asset is token0. Raw pool ratio is
///      `raw = human * 10^(dec1 − dec0) = priceWad * 10^(dec1 − dec0) / 1e18`.
///      Uniswap encodes `sqrtPriceX96 = √raw · 2^96`.
///
/// @dev **Derivation (fold decimal scale into Q96, not into the isqrt argument).**
///      ```
///      √raw · 2^96 = √(priceWad) · 2^96 / 1e9 · 10^((dec1−dec0)/2)
///      ```
///      When `|dec1−dec0|` is odd, multiply `priceWad` by 10 before isqrt so the
///      remaining scale exponent is an integer power of ten (no √10 in Q):
///      - `decDiff = dec1−dec0 ≥ 0` odd:
///        `√(priceWad·10) · 2^96 / 1e9 · 10^((decDiff−1)/2)`
///      - `decDiff < 0`, `k = −decDiff` odd:
///        `√(priceWad·10) · 2^96 / 1e9 / 10^((k+1)/2)`
///      Even negative diffs divide by `10^(k/2)` after isqrt — never
///      `priceWad / 10^k` before isqrt.
///
/// @dev **Why (bug).** Express V4 (`express-v4-deploy-2026-08`) scaled first:
///      `px = priceWad / 10^(dec0−dec1)` then `isqrt(px)`. For $MP,
///      `priceInStonkz = 40508986382159`, 18-dec token / 6-dec side →
///      `40508986382159 / 1e12 = 40`, `isqrt(40) = 6`, `6²/40 = 0.90` — a
///      permanent ~10% haircut harvested as side-pool spread. Ladder on the
///      same tag was decimals-blind (separate ×10^12 class error on 6-dec sides).
///
/// @dev **Precision guarantee.** Integer sqrt floors; relative error in implied
///      price is `< 2 / √(sqrtArg) + O(2^{-96})` where `sqrtArg` is `priceWad` or
///      `priceWad·10`. For side-pool `priceWad ≳ 1e10`, that is ≪ 0.2%. Equal
///      decimals (`dec0 == dec1`) bit-matches the historical WAD→Q96 path
///      (`isqrt(priceWad) · 2^96 / 1e9`).
///
/// @dev **Domain.** `dec0, dec1 ∈ [0, 18]` (see `tokenDecimals`). After invert,
///      `priceWad ∈ (0, type(uint256).max / 10]` when an odd diff requires `·10`
///      (else the `·10` step is skipped / unreachable for odd diffs with max
///      price). Output is clamped to `(TickMath.MIN_SQRT_RATIO,
///      TickMath.MAX_SQRT_RATIO)`. `priceWad == 0` after invert yields the
///      minimum usable sqrt (same clamp).
library SqrtPriceLib {
    uint256 internal constant WAD = 1e18;

    /// @notice Convert WAD human price to `sqrtPriceX96`, scaling for token decimals.
    /// @param priceWad Human token1/token0 in WAD (or token0/token1 before invert).
    /// @param pairIsToken0 If true, invert: encode token0/token1 as token1/token0.
    /// @param dec0 Decimals of currency0.
    /// @param dec1 Decimals of currency1.
    /// @return sqrtX96 Pool sqrt price in Q64.96, clamped to TickMath bounds.
    function sqrtPriceX96FromPriceWad(uint256 priceWad, bool pairIsToken0, uint8 dec0, uint8 dec1)
        internal
        pure
        returns (uint160 sqrtX96)
    {
        uint256 px = priceWad;
        if (pairIsToken0) {
            px = priceWad == 0 ? WAD : FixedPointMathLib.fullMulDiv(WAD, WAD, priceWad);
        }
        if (px == 0) return TickMath.MIN_SQRT_RATIO + 1;

        uint256 sqrtArg = px;
        uint256 scaleNum = 1;
        uint256 scaleDen = 1;

        if (dec1 >= dec0) {
            uint256 d = uint256(dec1) - uint256(dec0);
            if (d & 1 == 1) {
                // Absorb one power of ten into the radicand; remainder even.
                sqrtArg = px * 10;
                unchecked {
                    d -= 1;
                }
            }
            if (d != 0) scaleNum = 10 ** (d / 2);
        } else {
            uint256 d = uint256(dec0) - uint256(dec1);
            if (d & 1 == 1) {
                // √(px / 10^d) = √(px·10) / 10^((d+1)/2) — keep full px in isqrt.
                sqrtArg = px * 10;
                scaleDen = 10 ** ((d + 1) / 2);
            } else {
                scaleDen = 10 ** (d / 2);
            }
        }

        uint256 sqrtP = FixedPointMathLib.sqrt(sqrtArg);
        uint256 out = FixedPointMathLib.fullMulDiv(sqrtP, uint256(1) << 96, 1e9);
        if (scaleNum != 1 || scaleDen != 1) {
            out = FixedPointMathLib.fullMulDiv(out, scaleNum, scaleDen);
        }
        if (out <= TickMath.MIN_SQRT_RATIO) return TickMath.MIN_SQRT_RATIO + 1;
        if (out >= TickMath.MAX_SQRT_RATIO) return TickMath.MAX_SQRT_RATIO - 1;
        return uint160(out);
    }

    /// @notice Native ETH = 18; ERC20 via `decimals()` with 18 fallback (etched stand-ins).
    /// @dev Caps at 18 so `10**(dec diff)` stays in the derived domain above.
    function tokenDecimals(address t) internal view returns (uint8) {
        if (t == address(0)) return 18;
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && ret.length >= 32) {
            uint256 d = abi.decode(ret, (uint256));
            if (d <= 18) return uint8(d);
        }
        return 18;
    }
}
