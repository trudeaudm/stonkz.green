# Task H / O — Lazy-clearing decision record

**Ruling (Task O):** H1 accepted, conditional. This document is the decision
record (H4/H3 deferred with trigger conditions).

## Decision

| Choice | Status |
|--------|--------|
| H1 — eager fills; lazy empty-book only | **Shipped** |
| H2 — lazy position harvest via accumulator | **Deferred** (Task G made position ledger canonical; dual-write cost not the bottleneck) |
| H3 — exit tick buckets for OutPrice USD | **Deferred** (trigger below) |
| H4 — snapshot cursors for `committedLive` | **Deferred** (trigger below) |

## Gas measurement (Task O bench)

Harness: `contracts/test/GasBenchmark.t.sol` — 300 unique actives, wallet cap
100%, `epochSeconds=1`, Foundry `gasleft()` delta on `poke()`.

| Scenario | Clears / poke | Measured gas | vs 25M budget |
|----------|---------------|--------------|---------------|
| 300 actives × 32-clear catch-up | 32 (`maxClearsPerSync=32`) | **~235.3M** | **OVER** (~9.4×) |
| 300 actives × 1 clear | 1 | **~32.0M** | **OVER** (~1.3×) |

**Do not optimize the fill loop.** Per Task O: E1 (`maxClearsPerSync`) is the
mitigation for multi-clear catch-up. The bench proves the valve: wall lag 64
pending → one poke advances exactly 32 auction blocks and leaves
`pendingClears() == 32`.

**Surprise:** even a **single** clear at 300 actives (~32M) exceeds the 25M
budget. E1 alone does not make a 300-active clear fit a 25M tx — it only bounds
catch-up magnification (32× ≈ 235M). Production posture:

1. Keeper cadence (E2): poke at least once per epoch while `totalWeight > 0`
   so pending stays near 1 (see `docs/epoching-report.md`).
2. Expect unique-active counts well below 300 for guarded launch, or accept
   higher chain gas limits / further H4/H3 work if RH Chain block gas allows
   less than ~32M for a dense clear.
3. Revisit H4/H3 only under the triggers below — not fill-loop micro-opts.

## What stays eager (non-negotiable)

Per clear, in order (reference + Task L):

1. Price-out sweep at current `price` (weight + demand bases).
2. Competition ratchet after price-out.
3. Offer (sched + top-up) at that price.
4. Water-fill + position distribute.
5. Dust / exit refresh for the **next** clear’s weight basis.
6. Gate → optional price step; `auctionIndex++`.

Skipping or reordering these diverges from `reference/engine.js`.

## What is already lazy

| Mechanism | Laziness |
|-----------|----------|
| Empty-book cursor | Jump to wall target; no water-fill |
| `poke` / `placeBid` entry | Clears only on demand (`_sync`), capped by E1 |
| Claims | `_sync` then read position escrow |
| Timestamp epochs (Task N) | Wall time ≠ clear work; auction blocks only |

## Deferred options — trigger conditions

### H4 — Snapshot cursors for views

**Trigger:** profiles show `committedLive()` / view walks dominating gas on
user-facing RPCs or keeper preflight (not just clear loops). Require invariant
parity vs full position walk before shipping.

### H3 — Exit tick buckets

**Trigger:** cliff-heavy auctions (many OutPrice exits per clear) dominate
clear gas after H1+E1+keeper cadence is in production. Design must not weaken
Task L weight-basis timing (exits before offer/fill at the new price).

### H2 — Lazy harvest / H2+ materialization

**STOPPED after Task P.** Attribution shows bidder-slot SSTOREs dominate (~87%),
not position fills (~12%). A redesign that skips unconstrained **address**
refresh/harvest writes (not only position credit) is required before H2+.
See `docs/gas-attribution.md`.

## Non-goals

- Merging multiple auction blocks into one water-fill (E3 reject).
- Sponsoring gas on bids.
- Upgradeable clearing modules.
- Fill-loop micro-opts to chase the 25M budget at 300×32.

## Gate

H1 shipped. Gas numbers recorded. E1 valve verified under dense actives.
H3/H4 wait on production triggers above.

---

## Milestone 2.5 decision (Tasks P / Q / R)

| Item | Outcome |
|------|---------|
| Task P attribution | **Shipped** — `docs/gas-attribution.md` |
| H2+ lazy materialization (Task Q) | **Refuted / STOPPED** — per-position writes are only ~12% of SSTOREs; **per-address bidder writes ~87%** (`rewardDebt` + double `_refreshWeightBasisOnly` + fill bookkeeping). Do not implement Q as scoped until redesign targets unconstrained address writes. |
| Task R `maxUniqueActives` | **Shipped** — ctor param, 0 = unlimited; new addresses rejected past cap; existing may re-bid. Lifts with TVL caps (`docs/launch-plan.md`). |
| E1 + E2 keeper cadence | **Interim catch-up bounds** while H2+ redesign / M5 engine pending |

### Milestone-5 design note (cap removal at scale)

**Segment + heap engine** (not implemented now): closed-form geometric spend under
constant weight between constraints; exit-threshold priority queue so clears
touch storage only at constraint events (cap, budget/dust, price-out). That is
the path to remove `maxUniqueActives` at scale once equivalence-proven. Until
then: E1 valve + poke-at-least-once-per-epoch + unique-active cap.

