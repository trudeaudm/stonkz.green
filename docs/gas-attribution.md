# Clear-loop gas attribution (Tasks P / Q' / T)

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

## Task T (storage packing) — after

`Position` and `Bidder` each ≤ **2 storage slots** (`uint80` monetary fields +
bit flags; `PACKED_MAX ≈ 1.208e24` covers 1e6-ether supply / guarded-launch
USD with require guards on narrow writes).

| Measurement | Before packing | After packing | Notes |
|-------------|----------------|---------------|-------|
| Warm ALL-SIMPLE clear @300 | **~6.22M** | **~6.09M** | SLOAD pack win ~2% |
| WriteBudget warm SSTOREs | **8** | **8** | unchanged (ACC path) |

### Targets vs actual (STOP)

| Target | Actual | Status |
|--------|--------|--------|
| Warm ALL-SIMPLE @300 ≤ **2.5M** | **~6.09M** | **MISS** (~2.4×) |
| Catch-up gas ≤ **25M** at auto valve | derived cap × measured ≤ 25M | **PASS** (by construction) |

**Derived `maxClearsPerSync`:** `floor(25_000_000 / measured_warm) ≈ **4**`
(Params `0` selects this default). Assert in `GasBenchmark.test_gas_300actives_warm1clear_autoValve`:
`derivedCap * measured <= 25M`.

### Residual cost center

Packing cut bidder/position **slot count** but warm ALL-SIMPLE already had
**zero** unconstrained bidder SSTOREs (Q'). Remaining gas is **O(n) SLOAD +
memory water-fill** (~300 addresses × snap arrays × mulDiv). Segment+heap
(Milestone 5) required to approach 2.5M; E1 valve + `maxUniqueActives` +
keeper cadence remain the production bound.

### WriteBudget (design property — GREEN)

Warm unconstrained clear @300: **8 SSTOREs ≤ 16**. See `WriteBudget.t.sol`.
