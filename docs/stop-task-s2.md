# STOP — Task S2 exhaustion-boundary

**Date:** 2026-07-23  
**Gate:** Exhaustion-boundary exit BLOCK mismatch (eager vs lazy).  
**Task T:** not started. Production flip to lazy: **blocked**.

## Green

| Item | Status |
|------|--------|
| Pure acc tokens+USD all α (hybrid activeSpent writes dropped) | Done |
| Aggregates byte-identical (price/sold/raised/extraSold) on section-A + fuzz sample 20 | Green |
| Derived D = Σ 4×ceil(w_b/WAD) + P; size-tilt spent ds=87 ≤ D=109 | Green |
| WriteBudget warm unconstrained ≤16 (7 SSTOREs) | Green |
| Algebra documented in `implementation-notes.md` | Done |

## STOP trace — exit block

`ExhaustionBoundary.t.sol` — lazy exits **one auction block later** than eager in every weight case:

| Case | weight (ceil) | eagerExit | lazyExit |
|------|---------------|-----------|----------|
| α=0 / w=1 WAD | 1 (1) | 24 | 25 |
| tilt ~8.65 target | 2.84e18 (3) | 33 | 34 |
| tilt ~50 target | ~4.4e18 (5) | 70 | 71 |
| tilt ~500 target | ~6.1e18 (7) | 92 | 93 |

Attempts that did **not** close the lag (reverted or insufficient):

- Near-boundary materialize (2e9 and 1%-of-budget windows)
- End-of-unc-clear `_dustExhaustPositions` / `_markAllIn` when `snapBud ≤ snapSpent+1e9+pad`
- Capacity spent pad (broke sold byte-identity)

## Interpretation

1e9 epsilon ≫ weight-dust (≤7 wei/clear), so a 1-block lag is not “epsilon too tight” — it is **OutBudget timing**: eager marks during distribute mid-clear; lazy’s projected spent stays slightly under-credited so the same-clear exhaust mark does not fire, and exit lands on the next clear’s dust pass.

## Ruling needed

| Opt | Action |
|-----|--------|
| **E1** | Change OutBudget timing on lazy to match eager mid-clear (may need mechanism-adjacent care) |
| **E2** | Define exit-block as first index where remaining budget ≤ 1e9+D on **address** ledger (test-only), keep on-chain timing |
| **E3** | Accept 1-clear lag if invariants/fuzz stay green; drop hard exit-block assert |

Until then: CI stays on path that does not claim S2 complete; no Task T packing.

---

## RESOLVED — Task S3 (E1)

**Ruling:** E1 accepted. E2 rejected (blinds the test). E3 rejected (late exit =
extra block of fills; mechanism divergence).

### Diagnosis (confirmed)

Old lazy dust check used **pre-clear checkpoint only**:

```
snapSpent = activeSpent + pendingUsd(acc_before_b)   // excludes clear b's cost
dust iff budget ≤ snapSpent + 1e9
```

So after clear `b`'s fills, exhaust waited until clear `b+1`'s pre-clear pass —
one auction block later than eager (tables above).

### New operand (same-clear read-only projection)

Before the post-redistribution global acc write, compute final per-weight values
in memory (`accUsdAfter`), then for each unc participant:

```
projSpent(b) = activeSpent
             + floor(weight × (accUsdAfter − checkpoint) / WAD)
             // implemented as: activeSpent + floor(w·accUsdAfter/WAD) − usdDebt

dust-exhaust fires iff budget ≤ projSpent(b) + 1e9
```

Mark is **record-only** this clear (`exhaustProjSpent[who] = proj`); OutBudget is
**effective b+1** via the next clear's pre-clear dust — identical timing to eager.
No materialization writes during detection. `materialize()` asserts
`activeSpent == exhaustProjSpent[who]` (0 wei) when the projection was recorded.

### Exit tables (class a — budgets ≥ D from epsilon)

Lockstep harness (`ExhaustionBoundary.t.sol`); all four match eager exactly:

| Case | weight (ceil) | eagerExit | lazyExit |
|------|---------------|-----------|----------|
| α=0 / w=1 WAD | 1 (1) | 24 | 24 |
| tilt ~8.65 target | 2.84e18 (3) | 33 | 33 |
| tilt ~50 target | ~4.4e18 (5) | 70 | 70 |
| tilt ~500 target | ~6.1e18 (7) | 92 | 92 |

### Razor window (class b)

See `docs/implementation-notes.md` § Task S3 razor. Within D wei of the epsilon
crossing: `|lazyExit − eagerExit| ≤ 1` and fill Δ within fuzz tol
`max(1e12, 1e-9·scale)`.

