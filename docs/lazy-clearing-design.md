# Task H — Lazy-clearing design (docs only; not implemented)

Status: **for human review**. No code changes in this task.

## 1. Problem

Robinhood Chain ~100ms blocks forbid on-chain **per-wall-block** iteration
(`.cursorrules`). Today `_sync` already:

- **O(1)** jumps `auctionIndex` when `totalWeight == 0` (empty book).
- **O(pending × actives)** clears when the book is live.

“Lazy clearing” here means: **defer work that is not needed to answer the
current call**, without changing per-auction-block economics (spec §§3–6,
reference `tick()`).

Task E (epoching) covers *how many* clears a tx may run. This doc covers
*what* can be deferred inside or across clears.

## 2. What must stay eager (non-negotiable)

Per clear, in order (reference + Task L):

1. Price-out sweep at current `price` (weight + demand bases).
2. Competition ratchet after price-out.
3. Offer (sched + top-up) at that price.
4. Water-fill + position distribute.
5. Dust / exit refresh for the **next** clear’s weight basis.
6. Gate → optional price step; `auctionIndex++`.

Skipping or reordering these diverges from `reference/engine.js`.

## 3. What is already lazy

| Mechanism | Laziness |
|-----------|----------|
| Empty-book cursor | Jump to wall target; no water-fill |
| `poke` / `placeBid` entry | Clears only on demand (`_sync`) |
| Claims | `_sync` then read position escrow |
| MasterChef `accTokensPerWeight` | Present but fills are applied eagerly in clear (see notes §4 flag) |

## 4. Design options (for later implementation)

### H1 — Keep eager fills; lazy only empty-book (status quo)

Ship as-is. Document gas: worst case `durationBlocks` clears × active set.

### H2 — Lazy position harvest only

Stop dual-writing `Bidder.tokens` during clear; credit tokens only via
accumulator on `claim` / `bidderTokens` view. Weight basis and `sold`/`raised`
remain eager.

- Pros: less storage writes in water-fill.
- Cons: Task G wants a **single canonical ledger**; splitting address vs
  position balances fights that. Prefer G first.

### H3 — Exit tick buckets (price-indexed)

Record OutPrice exits in a tick bucket (spec already says “exits bucketed at
price ticks”). Process claimable USD lazily when price crosses the tick, O(1)
per poke amortized.

- Pros: large bidder sets with many cliffs.
- Cons: new storage; must still apply weight-basis removals **before** the
  clear that uses the new price (same as today’s `_priceOutAt`).

### H4 — Snapshot cursors for views

`currentOffer` / `effStepWad` already preview competition. Extend with a
cached `committedLive` updated only on OutPrice / placeBid (O(1) step),
instead of walking all positions.

- Pros: cheaper price steps under many positions.
- Cons: must stay exact vs view walk; invariant tests required.

## 5. Recommended sequence

1. **H1** through guarded launch (current code).
2. After Task G (canonical ledger), reconsider **H2** only if gas reports show
   position writes dominating.
3. **H4** if `committedLive` walk shows up in profiles.
4. **H3** only if cliff-heavy auctions dominate gas — design must not weaken
   Task L weight-basis timing.

## 6. Non-goals

- Merging multiple auction blocks into one water-fill (see Task E / E3 reject).
- Sponsoring gas on bids.
- Upgradeable clearing modules.

## 7. Gate

Design delivered for review. Implement nothing until human picks H1–H4.
