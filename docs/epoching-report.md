# Task E — Epoching report (docs only; not implemented)

Status: **for human review**. No code changes in this task.

## 1. What “epoch” means here

STONKZ already has two clocks:

| Clock | Storage | Advances when |
|-------|---------|----------------|
| Wall-clock | `block.number` (chain) | Every L2 block (~100ms on Robinhood Chain) |
| Auction cursor | `auctionIndex` | One step per `_clearOneBlock()` under `_sync()` |

`startBlock` anchors wall time at first `placeBid` / `poke`. Target cursor is
`min(durationBlocks, block.number − startBlock)`. That gap is the pending
**epoch of clears** the contract owes before reading offer/price/fills.

This report asks whether we should introduce an explicit **epoch** abstraction
(batch of clears, settlement boundary, or gas-metered work unit) beyond today’s
`auctionIndex` loop — and what would break if we did.

## 2. Current `_sync` behavior (as of main @ weight-basis fix)

```
if totalWeight == 0:
    auctionIndex := target          # O(1) empty-book jump; price frozen
else:
    while auctionIndex < target:
        _clearOneBlock()            # O(actives) water-fill each step
```

Implications:

1. **Dense demand + wall lag** — if a bidder is offline for `K` auction blocks
   while the book stays non-empty, the next `poke`/`placeBid` runs `K` clears
   in one tx. Gas scales ≈ `K × actives × water-fill iters` (capped by
   `durationBlocks` guard).
2. **Empty book** — cursor jumps; no per-wall-block work (required by 100ms
   rule / `.cursorrules`). Squish + thaw still match the reference when demand
   returns.
3. **Competition / price-out / weight basis** — evaluated **per auction block**,
   not per wall block. Epoching must not merge clears in a way that collapses
   price-out-before-fill or the one-clear dust lag (fuzz-halt-005 / Task L).

## 3. Options considered

### E0 — Status quo (recommend keep for Milestone 2)

Keep `auctionIndex` as the only epoch. Document gas bounds; rely on
guarded-launch raise caps to bound actives × duration.

- Pros: matches `reference/engine.js` tick-for-tick; already differentially tested.
- Cons: pathological `K`-clear catch-up can be expensive; no explicit
  “max clears per tx” UX.

### E1 — Soft gas epoch (`maxClearsPerSync`)

Ctor / immutable `maxClearsPerSync` (e.g. 32). `_sync` clears at most that many;
remainder stays pending; `poke` may need multiple calls.

- Pros: hard gas ceiling; simple.
- Cons: **diverges from reference** unless the oracle also pauses mid-schedule;
  frontend must poll `auctionIndex` vs wall; offers during partial catch-up need
  careful UX. **Would need human OK to change differential contract.**

### E2 — Keeper epoch (external poke duty)

Same as E0 mechanically, but ops/docs require a keeper to `poke` every N wall
blocks so user txs never shoulder large `K`.

- Pros: no mechanism change.
- Cons: liveness depends on keeper; empty-book still O(1) so keeper only matters
  when the book is live.

### E3 — True batched epoch (merge N schedule steps)

One tx applies a closed-form multi-block update (weights, price path) without
per-block water-fill.

- Pros: gas.
- Cons: **incompatible** with per-block price-out, water-fill constraints, and
  demand-scaled steps. Rejected for production mechanism fidelity.

## 4. Interaction with weight / demand bases (Task L)

Any epoch scheme must preserve:

1. Price-out for auction block `b` **before** `b`’s fills.
2. OutBudget / cap / dust exits from `b` visible to weight basis from `b+1`
   (reference snap semantics).
3. `committedLive` (demand) drops **only** on OutPrice, at the price-out tick.

Batching clears inside one tx is fine **iff** each clear still runs the full
`_clearOneBlock` body in order. Skipping or merging clears is not.

## 5. Recommendation

- **Ship E0** through guarded launch + fuzz/invariant CI.
- Add **ops note** (E2-style): while an auction has `totalWeight > 0`, a keeper
  or UI should `poke` periodically so organic bids rarely clear dozens of
  blocks at once.
- Revisit **E1** only if mainnet gas profiling shows catch-up txs failing; treat
  as a product change with oracle+consumer updates, not a silent Sol patch.
- Do **not** pursue E3.

## 6. Gate

Document delivered. No implementation. Human chooses E0/E1/E2 before any
follow-on code.
