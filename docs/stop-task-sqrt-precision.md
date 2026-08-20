# STOP — SQRT PRECISION LOSS IN SIDE-POOL INIT

**Branch:** `fix/sqrt-precision` (from `deploy/mainnet-2026-08` → FF `express-v4-deploy-2026-08` / `fix/express-mint`)  
**Gate:** PUSHED. No deploy prep. David rules whether this bundles with ladder settlement rework.

---

## 1. DIAGNOSIS (Express V4 — tag `express-v4-deploy-2026-08`)

Buggy path in `StonkzDirectListing.sol` (tag lines 559–582):

```solidity
/// @dev Convert WAD human price to sqrtPriceX96. Scales by 10^(dec1−dec0) before sqrt …
function _sqrtPriceFromPriceWad(uint256 priceWad, bool pairIsToken0, uint8 dec0, uint8 dec1)
    internal pure returns (uint160)
{
    uint256 px = priceWad;
    if (pairIsToken0) {
        px = priceWad == 0 ? WAD : FixedPointMathLib.mulDiv(WAD, WAD, priceWad);
    }
    // Raw token1/token0 = human * 10^(dec1 − dec0). Apply before sqrt.
    if (dec1 >= dec0) {
        unchecked { px = px * (10 ** (dec1 - dec0)); }
    } else {
        px = px / (10 ** (dec0 - dec1));   // ← PRECISION DESTROYED HERE
    }
    uint256 sqrtP = _sqrt(px);
    uint256 sqrtX96 = FixedPointMathLib.fullMulDiv(sqrtP, uint256(1) << 96, 1e9);
    …
}
```

### $MP sequence (`0x86D0a2FE…Df78`)

| Step | Value |
|---|---|
| `startPriceWad` | `17309044637` |
| `refPriceWad` | `427289008757403` |
| `priceInStonkz` | `40508986382159` (≈ **4.0509e-5** human) |
| Orientation | tokIs0 (token `0x4663…` < side `0x5fc5…`); `dec0=18`, `dec1=6`; no invert |
| Decimal adj | `40508986382159 / 10^12 = **40**` (truncation) |
| `isqrt(40)` | **6** |
| `6²/40` | **0.90** → permanent **~10%** haircut on √ → **11.13%** on price |
| Live side tick | `sideTickLower=-378600` → spotAligned `−378660` (matches buggy path, not target `−377469`) |

LadderSettlement on the same tag (line ~548) was **decimals-blind** — separate `×10^12` class error on 6-dec sides.

---

## 2. FIX — `SqrtPriceLib`

Shared library: `contracts/src/SqrtPriceLib.sol`.

**Derivation:** do not divide `priceWad` before isqrt. Fold `10^((dec1−dec0)/2)` into the Q96 conversion after `√(priceWad)` (or `√(priceWad·10)` when `|decDiff|` is odd).

**Precision:** relative implied-price error `< 2/√(sqrtArg) + O(2^{-96})`. For live side magnitudes ≪ 0.2%. Equal decimals bit-matches the historical WAD path.

**Domain:** `dec0,dec1 ∈ [0,18]`; output clamped to TickMath sqrt bounds.

Both `StonkzDirectListing` and `LadderSettlement` call **only** this library (main + side).

---

## 3. BLAST RADIUS (live Express, @$1 stand-in)

Intended = correct sqrt at stamped `priceInStonkz`. Actual = live buggy init. FDV = human × supply @$1/side.

| Token | Listing | `priceInStonkz` | Intended side human | Actual (buggy) | Truncation gap | Intended FDV@$1 | Actual FDV@$1 |
|---|---|---|---|---|---|---|---|
| **SDONK** | `0x47c32081…e042` | `3.9999e15` | `3.9999e-3` | `3.969e-3` | **0.77%** | $3999.89 | $3969.00 |
| **MOONER** | `0xc85eCA75…9E07` | `3.9808e13` | `3.9808e-5` | `3.6e-5` | **9.57%** | $3980.84 | $3600.00 |
| **THOOK** | `0xce1476aC…F891` | `3.2266e13` | `3.2266e-5` | `2.5e-5` | **22.52%** | $3226.61 | $2500.00 |
| **MP** | `0x86D0a2FE…Df78` | `4.0509e13` | `4.0509e-5` | `3.6e-5` | **11.13%** | $4050.90 | $3600.00 |

Note: THOOK/MP intended FDV@$1 also sit below main’s $4k when stamped `ref` is stale vs `ethUsdWad` (separate ref-drift wedge). Truncation is the structural extra haircut searchers harvest on every post-decimals-aware Express list.

BONZI / T predate the decimals-aware path (different bug class).

---

## 4. TESTS

`contracts/test/SqrtPrecision.t.sol`: MP fixture (≤0.2%, not old sqrt); live SDONK/MOONER/THOOK/MP; precision sweep 18/18, 18/6, 6/18, 8/18; Ladder 6-dec side ≠ decimals-blind.

Related green: ExpressPricingFix, SidePoolPriceLock (Mock+Real), SidePoolRefPrice.

`forge doc` / `forge doc --build`: exit 0; NatSpec on `SqrtPriceLib`.

Full suite: **305 passed, 1 failed, 0 skipped (306 total)**.  
Failing: `ForkCanonPhase4::test_P4_fork_fullDrillManifest` — `EthUsdStampDrift(1880e18, ~2320e18)` live-RPC ethUsd freshness vs hardcoded stamp. Unrelated to sqrt precision (pre-existing fork drift).

---

## 5. RULING REQUEST

**Do not prepare a deploy.** David: bundle this with ladder settlement rework, or ship Express template-only first?
