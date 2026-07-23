# StonkzAuction — implementation notes

Milestone-1 notes for review (refreshed post Tasks M/N/O). Spec:
`docs/mechanism-spec.md`. Oracle: `reference/engine.js`.

## 1. Storage layout

**Immutables (ctor):** `totalSupply`, `launchSupply`, `auctionSupply`,
`reserveInitial`, `floorPrice`, `floorMcapUsd`, `graduationUsd`,
`durationBlocks`, `epochSeconds`, `maxClearsPerSync`, `baseStepBps`,
`walletCapBps`, `sizeBonusBps`, `lpShareBps`, `holdbackBps`,
`kappaHundredths`, `disposalMode`, `pairToken`, `creator`, `alphaWad`.

**Schedule:** `weights[]`, `weightSuffix[]` (Σ from i..N), `flatBase`.

**Cursor / book:** `startTime`, `auctionIndex`, `price`, `sold`, `raised`,
`extraSold`, `lastSoldPrice`, `competition`, `done`, `graduated`, `settled`.

**Share accounting:** `accTokensPerWeight`, `totalWeight`; per-bidder
`Bidder{weight, rewardDebt, tokens, activeBudget, activeSpent, activeCount,
capped, tracked}`; `activeAddrs[]` + `_activeIdx`.

**Positions:** `positions[id] → Position{owner, budget, maxPrice, spent,
tokens, status, usdClaimed, tokensClaimed}`; `_bidderPositions[addr]`.

**Escrow:** `claimableUsd`, `claimableTokens`, `totalEscrowed`,
`totalTokensCredited`, `totalTokensForfeited`, `nextPositionId`.

## 2. Accumulator / ledger (Task G)

Each **address** is one weighted share: `weight = committedCapital^α`
(`α = log2(1+sizeBonus)`, `α=0 ⇒ weight=WAD`). All of an address’s active
positions share that weight (no self-sybil).

**Canonical token ledger:** Σ `position.tokens` (+ claimable / forfeited
bookkeeping via `tokensAccounted()`) is the source of truth for fills and
claims. Conservation: `tokensAccounted() == sold` (exact) under the invariant
handler, including mid-auction `claim()` interleaving (Task M).

**`accTokensPerWeight` / `accUsdPerWeight` / `Bidder.tokens`:** Task Q' lazy path
credits unconstrained fills via accumulators; materialize on touch/exit. Eager
path (`eagerFills=true`) keeps per-clear position writes for vector oracle
parity until EagerLazyEquivalence is wei-green. Position ledger is canonical
**after** `materialize` / `materializeAll`.

**Exits bucketed at price ticks:** on clear, positions with `maxPrice < price`
→ `OutPrice` before offer/fill. Caps / all-in mark out and drop weight.

**`poke()` / `_sync()` (Task N):** target =
`min(N, (block.timestamp − startTime) / epochSeconds)`.
- `totalWeight == 0` (empty book): **O(1)** jump of `auctionIndex`.
- Else: at most `maxClearsPerSync` clears per call (E1; default 64).
- `pendingClears()` is honest while lagging; views read the cleared cursor.

Complexity: never iterate idle wall time; cost scales with unique actives ×
auction blocks cleared (capped per tx).

## 3. Spec §§3–8 → code

| Spec | Formula / rule | Location |
|------|----------------|----------|
| §3 | `α = log2(1+sizeBonus)` | `StonkzAuction.sol` ctor |
| §3 | `weight = capital^α` | `StonkzAuction.sol:_weightOf` |
| §3 | Water-fill by weight; exits | `StonkzAuction.sol:_clearOneBlock` |
| §4 | Gate = original schedule | `_clearOneBlock` gate branch |
| §4 | `effStep = 1 + base×(1+live/grad)` | `effStepWad` |
| §5 | Weights 40/60, handoff | `LadderWeights.sol:makeWeights` |
| §5 | Squish `rem×w[b]/Σw[b..]` | `_schedAt` |
| §5 | Flat while `!competition` | `_schedAt` + ratchet in clear |
| §6 | Guard top-up | `_offeredAt` |
| §7 | κ̂∶LP split | ctor |
| §7 | Raise ceiling | `_raiseCeiling` |
| §7 | Fail ⇒ full refund | `claim` failure path; `runAway` |
| §8 | Pair `F/P`; leftover buckets | `settle` |

## 4. Rounding policy

Solady `mulDiv` / `mulWad` are **floor** (dust truncated toward zero).
Guarantee aimed: **protocol never underflows; bidders never overdrawn.**

| Site | Direction | Dust eater | Notes |
|------|-----------|------------|-------|
| `_schedAt` mulDiv rem×w/Σ | floor | leftover rem (later blocks) | Squish preserves remainder |
| Share `remaining×w/totW` | floor | `remaining` loop / unsold | Unsold ≤ dust×actives |
| `take*price` mulWad | floor | bidder (slightly under-charged) | `spent ≤ budget` enforced |
| `budLeft/price` mulDiv | floor | bidder capacity | Never overdraws budget |
| Top-up drain/need | floor | reserve (less sold) | Guard uses floored need → **conservative slack** |
| Price step mulWad | floor | slightly slower climb | Gate still schedule-based |
| Weight powWad | approx | relative fills | Ratios match engine within 1e18 tests |
| Position `d/live` | floor | address-level remainder loop | Inner water-fill ≤6 iters |
| `claim` unspent | exact `budget−spent` | — | USD/token claims independent (Task M) |
| Lazy address total `floor(w·Δacc)` | floor | settle dust → pairing surplus | Task S2 |
| Lazy position split `d/live` + LR | floor + largest-remainder | rem → lowest `positionId` | Tokens first; spent pro-rata to token shares |

### Task S2 — derived weight-dust bound (eager vs lazy)

Pure accumulator for **tokens and USD at all α** (no per-taker spent SSTOREs).

**Per clear**, unconstrained fills credit:

```
acc += floor(amount × WAD / uncW)     // global per-weight write
```

Harvest:

```
credit = floor(w × acc / WAD) − debt
```

Relative to the exact rational share `w/uncW × amount`, a single floor chain
contributes **at most `ceil(w/WAD)` wei** to the address (each WAD of weight can
lose <1 wei at the `×WAD/uncW` write, recovered as `< w/WAD` on harvest).

USD compares lazy credits to eager `Σ mulWad(take, px)`. That path has **three**
sequential WAD-scale floors per clear:

1. `take = floor(rem × w / totW)`  
2. `cost = floor(take × px / WAD)` (`mulWad`)  
3. `accUsd += floor(Σcost × WAD / uncW)`  
4. `pendU = floor(w × accUsd / WAD) − debt`  

Each stage contributes **at most `ceil(w_b/WAD)` wei** at the address when
propagated through WAD-scaled mulDivs, so per clear the bound is
`4 × ceil(w_b/WAD)`. Summing over live blocks and adding LR slack
`P = #positions of the address`:

```
D = Σ_{active blocks b} 4 × ceil(weight_b / WAD)  +  P
```

Assert `|eager − lazy| ≤ D` per position for **tokens and spent**. Aggregates
`price/sold/raised/extraSold` stay **byte-identical** per auction block.
Conservation post-`materializeAll`+settle is **exact** via `settleDustSurplus`.

`eagerFills=true` is **test-only** (`EagerLazyEquivalence`). Production / CI /
fuzz / invariants use `eagerFills=false`.

### Task S3 — same-clear projSpent + razor window

**Diagnosis:** dust-exhaust used pre-clear `pendingUsd(acc_before)` and missed
clear `b`'s cost → one-block exit lag vs eager.

**Fix:** after computing `accUsdAfter` (block `b`'s unc delta included), for each
unc taker:

```
projSpent = activeSpent + floor(w · accUsdAfter / WAD) − usdDebt
dust iff budget ≤ projSpent + 1e9   // record exhaustProjSpent; mark OutBudget at b+1
```

`materialize` asserts credited spent equals recorded projection (0 wei).

**Razor window.** Let `D` be the Task S2 weight-dust bound for the address
(`Σ 4×ceil(w_b/WAD) + P`, or the duration-safe upper
`4×ceil(w/WAD)×durationBlocks + 1` used in `ExhaustionBoundary`).

Derivation of the ±1 exit allowance: floor chains can place `projSpent` up to
`D` wei below the eager position ledger at the epsilon crossing. When
`budget − eagerSpent` lands in `(1e9 − D, 1e9 + D)`, lazy may trip dust one
clear earlier or later than eager while still obeying `budget ≤ spent + 1e9` on
its own ledger. Outside that window (class a), exit blocks match exactly.

Class b asserts `|Δexit| ≤ 1` and per-address fill Δ ≤ fuzz tol
`max(1e12, scale/1e9)`.

## 5. Gas (post M/N/O)

Routine suite (`forge test --gas-report --match-contract StonkzAuctionTest`,
post M/N; excludes the 300-active stress bench):

| Fn | Min | Avg | Median | Max | Calls |
|----|-----|-----|--------|-----|-------|
| `placeBid` | 168k | 311k | 292k | 381k | 71 |
| `poke` | 26k | 286k | 208k | 1.25M | 215 |
| `claim` | 71k | 71k | 71k | 71k | 1 |
| `settle` | 26k | 35k | 40k | 40k | 3 |

`poke` max is dense live-book catch-up within the E1 valve; empty-book stays near min.

**Stress bench** (`GasBenchmark.t.sol`, Task O) — decision numbers:

| Scenario | Gas |
|----------|-----|
| 300 actives × 32 clears / poke | ~235.3M (over 25M budget) |
| 300 actives × 1 clear / poke | ~32.0M (over 25M budget) |

Mitigation: E1 valve + E2 keeper cadence; see `docs/lazy-clearing-design.md`.
Deploy remains ~4.3M gas class / ~22kB runtime size (re-measure on release tag).
