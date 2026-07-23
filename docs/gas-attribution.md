# Clear-loop gas attribution (Tasks P / Q')

## Task P (before Q') — bidder SSTORE dominance

| Measurement | Gas | Notes |
|-------------|-----|-------|
| Clear #1 after seed | **~31.4M** | ~1204 zero→nonzero SSTOREs |
| Clear #2 warm | **~7.43M** | mutate-only |
| 32-clear `poke` | **~234.7M** | avg **~7.33M**/clear |

Per clear @ 300 actives: ~4806 SSTOREs — **bidder ~87%**, position ~12%, globals ~0%.

## Task Q' (lazy materialization) — after

| Measurement | Gas | SSTOREs | Notes |
|-------------|-----|---------|-------|
| Clear #1 (lazy) | **~4.79M** | **8** | globals only |
| Clear #2 warm (lazy) | **~4.71M** | **7** | WriteBudget ≤16 **PASS** |
| 32-clear `poke` (lazy) | **~187–193M** | — | avg ~6.0M/clear |

Bidder/position write ops on unconstrained warm clear: **0**.

### Targets vs actual (STOP)

| Target | Actual | Status |
|--------|--------|--------|
| Warm single clear @300 ≤ **3M** | **~4.71M** | **MISS** (~1.57×) |
| 32-clear catch-up @300 ≤ **30M** | **~187M** | **MISS** (~6.2×) |

### Residual cost center

SSTORE elimination succeeded. Remaining gas is **O(n) SLOAD + memory water-fill**
(~9k SLOADs/clear, projection loops). Segment+heap (Milestone 5) is required
to cut read/compute; E1 + `maxUniqueActives` + keeper cadence remain interim bounds.

### Equivalence

`EagerLazyEquivalence`: fuzz sample 20 passed; section-A `canonical-abc` /
`size-tilt` **diverge on per-position tokens after materialize** (globals often
match). Vectors/CI keep `eagerFills=true` until wei-identical materialization
is fixed. Lazy path (`eagerFills=false`) is gated by WriteBudget + benches.

### WriteBudget (design property — GREEN)

Warm unconstrained clear @300: **7 SSTOREs ≤ 16**. See `WriteBudget.t.sol`.
