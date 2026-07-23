# Task E / N — Epoching decision record

**Ruling (Task N):** implement timestamp epochs + E1 valve. This document is the
decision record (E0 semantics preserved at the auction-block layer).

## Decision

| Choice | Status |
|--------|--------|
| E0 — auction-block clears match reference tick-for-tick | **Kept** |
| Timestamp epochs (`epochSeconds`) replace `block.number` wall anchor | **Shipped (Task N)** |
| E1 — `maxClearsPerSync` (default 64) | **Shipped (Task N)** |
| E2 — keeper cadence while book is live | **Ops recommendation** (below) |
| E3 — batched multi-block water-fill | **Rejected** |

## Mechanics (shipped)

- `auctionBlock` target = `min(N, (block.timestamp − startTime) / epochSeconds)`.
- `startTime` set on first `placeBid` / `poke` (same role as former `startBlock`).
- Constructor: `epochSeconds ∈ [1, 3600]`; `durationBlocks ∈ [5, 2000]`
  (production launches should use **N ∈ [100, 2000]**; lower bound 5 retained so
  differential vectors deploy unchanged).
- `maxClearsPerSync`: `0` ⇒ 64. Live-book `_sync` clears at most that many per
  call; empty-book still O(1) jumps the cursor.
- `pendingClears()` exposes wall lag. Views (`currentOffer`, etc.) read the
  **cleared** cursor — honest while lagging.

## Keeper cadence (E2 ops note)

While `totalWeight > 0`, poke **at least once per epoch** (ideally every
`epochSeconds`) so user txs rarely shoulder large catch-up. Empty book needs no
keeper (O(1) jump).

## Vectors / oracle

Untouched. Foundry harness uses `epochSeconds = 1` and `vm.warp` so one second
== one auction block (same schedule as former `vm.roll` +1).

## Tests

- `EpochSync.t.sol`: partial sync (cap 2) vs full sync → identical price / sold /
  raised / fills after catch-up.
