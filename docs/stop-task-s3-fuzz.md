# STOP — Task S3 production flip / 200-vector fuzz

**Date:** 2026-07-23  
**Gate:** `testFuzzVectors_seed4663_all200` HALT after `eagerFills=false` flip.  
**Task T:** not started.

## Green before flip

| Item | Status |
|------|--------|
| S3 projSpent same-clear detection + materialize 0-wei assert | Done |
| Exhaustion class (a) four weights — exit blocks match eager | Green |
| Exhaustion class (b) razor — `|Δexit|≤1`, fill Δ within fuzz tol | Green |
| EagerLazy section-A + fuzz sample 20 — aggregates byte-identical | Green |
| WriteBudget warm unconstrained 7 SSTOREs | Green |
| Docs: `stop-task-s2.md` RESOLVED + razor in `implementation-notes.md` | Done |
| Production tests flipped to `eagerFills=false` (eager retained in Equivalence) | Done |

## HALT — fuzz seed 4663 scenario 5 block 24 fill=B

**Vector:** `test/vectors/fuzz/fuzz-005.json`  
**Symptom:** `|gotFillB − expFillB| > TOL (1e18)`.

### Mini-trace (eager vs lazy lockstep)

| block | eager Δtok B | lazy Δtok B | eAct | lAct |
|------:|-------------:|------------:|-----:|-----:|
| 20 | ≈1.899e19 | ≈1.899e19 | 1 | 1 |
| 21 | ≈1.989e19 | ≈1.989e19 | 1 | 1 |
| 22 | ≈2.079e19 | ≈2.079e19 | 1 | 1 |
| 23 | ≈2.079e19 | ≈2.079e19 | 1 | 1 |
| **24** | **≈2.995e19** | **0** | **1** | **1** |
| 25 | ≈2.176e19 | ≈2.274e19 | 1 | 1 |
| 26 | ≈6.25e17 | ≈2.959e19 | 0 | 0 |

Oracle expects B fill at block 24 ≈ `29946789355925630976`. Lazy leaves B **Active** but credits **zero** tokens that clear; block 25–26 overshoot relative to eager.

Also failing under the same flip (not independently gated):

- `invariant_exactWeiLedger` — `tokensAccounted` vs `sold` off by 1 wei  
- `testInvariant_exactWeiLedger_sizeTilt` — `Σ position.spent` vs `raised` Δ=109 (equals S2 D-bound; test still uses maxΔ=2)

## Interpretation

Not an exit-block lag: both paths show B Active through clear 24. Lazy water-fill assigns B **no take** (or take that never becomes bidder credit) while eager distributes a full share. Suspect candidates (not yet proven):

1. Pre-clear dust + `alive[]` left true → `takeAmt` recorded / sold bumped but `dustExit` excluded from `uncW` so no acc harvest and no distribute.  
2. Virtual `snapSpent` / cap interaction unique to pending USD under α≠0 multi-position B.

## Ruling needed

| Opt | Action |
|-----|--------|
| **F1** | Fix lazy clear so Active addresses with budget/cap headroom always receive the same take as eager (then re-run 200 + invariants) |
| **F2** | Widen fuzz fill bar to D-bound for lazy (rejects: blinds real zero-fill bug above) |
| **F3** | Keep CI on eager for fuzz/invariants until F1 lands |

**Task T blocked** until fuzz gate is green under production=lazy.
