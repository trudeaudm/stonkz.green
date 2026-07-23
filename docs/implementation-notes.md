# StonkzAuction — implementation notes

Milestone-1 notes for review. Spec: `docs/mechanism-spec.md`. Oracle: `reference/engine.js`.

## 1. Storage layout

**Immutables (ctor):** `totalSupply`, `launchSupply`, `auctionSupply`, `reserveInitial`, `floorPrice`, `floorMcapUsd`, `graduationUsd`, `durationBlocks`, `baseStepBps`, `walletCapBps`, `sizeBonusBps`, `lpShareBps`, `holdbackBps`, `kappaHundredths`, `disposalMode`, `pairToken`, `creator`, `alphaWad`.

**Schedule:** `weights[]`, `weightSuffix[]` (Σ from i..N), `flatBase`.

**Cursor / book:** `startBlock`, `auctionIndex`, `price`, `sold`, `raised`, `extraSold`, `lastSoldPrice`, `competition`, `done`, `graduated`, `settled`.

**Share accounting:** `accTokensPerWeight`, `totalWeight`; per-bidder `Bidder{weight, rewardDebt, tokens, activeBudget, activeSpent, activeCount, capped, tracked}`; `activeAddrs[]` + `_activeIdx`.

**Positions:** `positions[id] → Position{owner, budget, maxPrice, spent, tokens, status}`; `_bidderPositions[addr]`.

**Escrow:** `claimableUsd`, `claimableTokens`, `totalEscrowed`, `nextPositionId`.

## 2. Accumulator design

Each **address** is one weighted share: `weight = committedCapital^α` (`α = log2(1+sizeBonus)`, `α=0 ⇒ weight=WAD`). All of an address’s active positions share that weight (no self-sybil).

**Fills:** per auction block, water-fill over `activeAddrs` proportional to weight; constrained exits redistribute (spec §3). Position-level equal water-fill splits the address take.

**Exits bucketed at price ticks:** on clear, positions with `maxPrice < price` → `OutPrice` before offer/fill. Caps / all-in mark out and drop weight.

**`poke()` / `_sync()`:** target = `min(duration, block.number − startBlock)`.
- `totalWeight == 0` (empty book): **O(1)** jump of `auctionIndex` (price frozen; squish applies when demand returns).
- Else: clear each pending auction block — **O(actives)** water-fill, **not** O(wall-clock empty blocks).

Complexity: with 100ms blocks, never iterate idle wall time; cost scales with unique actives × auction blocks cleared, not with elapsed chain blocks while the book is empty.

## 3. Spec §§3–8 → code

| Spec | Formula / rule | Location |
|------|----------------|----------|
| §3 | `α = log2(1+sizeBonus)` | `StonkzAuction.sol:142–149` |
| §3 | `weight = capital^α` | `StonkzAuction.sol:_weightOf` (~719) |
| §3 | Water-fill by weight; exits | `StonkzAuction.sol:_clearOneBlock` 455–528 |
| §4 | Gate = original schedule | `StonkzAuction.sol:536–548` |
| §4 | `effStep = 1 + base×(1+live/grad)` | `StonkzAuction.sol:399–404` |
| §5 | Weights 40/60, handoff | `LadderWeights.sol:makeWeights` |
| §5 | Squish `rem×w[b]/Σw[b..]` | `StonkzAuction.sol:_schedAt` 785–796 |
| §5 | Flat while `!competition` | `StonkzAuction.sol:792–794`, ratchet ~220, 447–449 |
| §6 | Guard top-up | `StonkzAuction.sol:_offeredAt` 798–827 |
| §7 | κ̂∶LP split | `StonkzAuction.sol:134–140` |
| §7 | Raise ceiling | `StonkzAuction.sol:_raiseCeiling` 164–177 |
| §7 | Fail ⇒ full refund | `claim` 254–256; `runAway` 294–302 |
| §8 | Pair `F/P`; leftover buckets | `settle` 306–331 |

## 4. Rounding policy

Solady `mulDiv` / `mulWad` are **floor** (dust truncated toward zero). Guarantee aimed: **protocol never underflows; bidders never overdrawn.**

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
| `claim` unspent | exact `budget−spent` | — | Failure path refunds full `budget` |

**Flag:** `accTokensPerWeight` is maintained for harvest bookkeeping but **fills are applied eagerly** in `_clearOneBlock`, not solely via accumulator deltas. Dust between `bd.tokens` and Σ `position.tokens` is possible at wei scale; claims use position accounting after sync. Differential suite holds at 1e18 abs tol; tighter wei conservation across all positions is **not** proven here.

## 5. Gas (`forge test --gas-report`)

| Fn | Min | Avg | Median | Max | Calls |
|----|-----|-----|--------|-----|-------|
| `placeBid` | 171k | 316k | 311k | 381k | 66 |
| `poke` | 26k | 253k | 190k | 1.16M | 193 |
| `claim` | 49k | 49k | 49k | 49k | 1 |
| `settle` | 26k | 35k | 40k | 40k | 3 |

Deploy ~4.35M gas / 21.6kB. `poke` max spikes when clearing a dense active set; empty-book poke stays near the min.
