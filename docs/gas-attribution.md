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

**Amended ruling (pre-m5-housekeeping, code is source of truth):** `Position` and
`Bidder` are each **3 storage slots**, not 2. Monetary quantities are `uint112`;
user-supplied `maxPrice` is `uint128` (domain requires sentinel room up to
~1e27 / `uint128.max` — a prior `uint80` pack was a domain error vs fuzz seed
4663). Layout in `StonkzAuction.sol`:

| Struct | Slots | Fields |
|--------|-------|--------|
| `Position` | 3 | s0: `uint112 budget` + `uint128 maxPrice`; s1: `uint112 spent` + `uint16 enteredAt` + `uint112 tokens`; s2: `address owner` + `PosStatus` + `uint8 claimFlags` |
| `Bidder` | 3 | s0: `uint112 weight` + `uint112 activeBudget`; s1: `uint112 activeSpent` + `uint16 activeCount` + `uint112 rewardDebt`; s2: `uint112 usdDebt` + `uint112 tokens` + `uint8 flags` |

Measured warm ALL-SIMPLE clear **~6.09M** stands regardless of the doc correction.

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

Packing cut bidder/position **slot width** but warm ALL-SIMPLE already had
**zero** unconstrained bidder SSTOREs (Q'). Remaining gas is **O(n) SLOAD +
memory water-fill** (~300 addresses × snap arrays × mulDiv). Segment+heap
(**SCALE-TRACK** — gated on measured gas, not milestone sequence; owner ruling:
M5 = Ladder v1.5) required to approach 2.5M; E1 valve + `maxUniqueActives` +
keeper cadence remain the production bound.

### WriteBudget (design property — GREEN)

Warm unconstrained clear @300: **8 SSTOREs ≤ 16**. See `WriteBudget.t.sol`.
