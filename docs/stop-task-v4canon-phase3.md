# STOP update — V4-CANON Phase 3 geometry fix (ruling option 2)

**Branch:** `feat/v4-canon`  
**Ruling:** Hold Phase 4 until Ladder settle green on in-test real PM — **CLEARED**.

## Diagnosis (suspect order)

| # | Suspect | Result |
|---|---|---|
| **(1)** | Liquidity math vs wrong tick bounds after alignment | **ROOT CAUSE.** `floorTick`/`printTick` were swapped for “ordering,” so bounds no longer matched initialized `printSqrt`. Under `pairIs0` (native), ask was placed on the wrong side of spot for token1 composition. |
| (2) | Settle/take ordering shorting a currency mid-unlock | Not primary — fixed once legs were single-sided pure. |
| (3) | Dust `liq=1` | Confirmed harmful on Real; **retired**. Positive amount + zero L → `LiquidityDust(leg)` revert (explicit). No silent mint. Not a docs/09 §7 change; addendum only if prod sizes hit it — flag only. |

## Fix (spec §7 unchanged)

Price geometry still cash `[floorPrice, printPrice]`, tokens `[printPrice, ∞)`, side single-sided.

Construction now orientation-aware for real PM:
- **pairIs0:** cash ticks `(print, floor]` (spot below → pure token0); ask `[min, print]` (spot at/above upper → pure token1).
- **!pairIs0:** cash `[floor, print]` (above-range → pair=c1); ask `(print, max]` (below-range → token=c0).
- Liq via `getLiquidityForAmount0/1` only (no current-price mix).
- Side pool: same composition rules; usable min tick via `_alignUp(MIN_TICK)`.

## Proof

- `test_real_A1A5_09_settleOnAdapter` PASS (cash+ask+side on V4Adapter).
- A1–A5 × 10 Real PASS; Mock `LadderPhase3` PASS; Express `DirectListing` + `ListingAdapterPhase2` Mock|Real PASS.
- Vectors byte-identical; tolerances unchanged.

## Next

Phase 4 fork gate vs RH singleton `0x8366…`.
