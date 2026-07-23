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

**`accTokensPerWeight` / `Bidder.tokens`:** retained only for **weight
coherence** (MasterChef-style harvest when weight changes). They are **not**
the claim path and must not diverge mechanism math. Fills are still applied
eagerly to positions in `_clearOneBlock`. Do not reintroduce dual-ledger claim
credit (H2 deferred indefinitely — see `docs/lazy-clearing-design.md`).

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
