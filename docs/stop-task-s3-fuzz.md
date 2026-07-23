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

---

## RESOLVED — F1 circularity hypothesis (REFUTED)

**Ruling executed:** F1. Reject F2/F3.  
**Hypothesis tested first:** post-b `projSpent(b)` leaked into take / `budLeft` so
lazy `budLeft_24(B) ≈ 0` while eager pre-b headroom funded the ~3.00e19 fill.

### Operands at block 24 (B, pre-clear, after realizing pending via `materialize`)

| Operand | Lazy | Eager |
|---------|-----:|------:|
| `budget` | 10778582661952823099392 | 5668359750236850094080 |
| `projSpentPre` (= spent+pending through b−1) | **6520653441624567416249** | 1405443370877568320988 (eager ledger) |
| `budLeft_pre` = budget − projSpentPre | **4257929220328255683143** | **4262916379359281773092** |
| `capLeft` | 52330803725715015130 | — |
| `offer` | 29946789355925612793 | same class |
| `budget ≤ projSpentPre + 1e9` (dust eps) | **false** | — |

Eager `budLeft_pre ≈ 4.26e21` ≫ cost of the ~3.00e19-token fill.  
Lazy `budLeft_pre ≈ 4.26e21` as well — **not ≈ 0**.

Code audit: water-fill reads `snapSpent = activeSpent + pendingUsd` captured
**before** clear b (pre-b only). Same-clear `exhaustProjSpent` / `accUsdAfter`
are computed **after** the take loop and do not write back into `snapSpent` /
`budLeft` in the same clear. **No post-b → take leakage in-code.**

### Verdict: REFUTED

Circularity / post-b operand in take path is **not** the dropped-fill cause.
Per F1 instruction: **STOP here — do not improvise a fix.**

### Smoking gun (actual mechanism of the halt — for next ruling)

At block 24 lockstep:

| Signal | Lazy | Eager |
|--------|-----:|------:|
| `dSold` | 29946789355925612793 | 29946789355925612793 |
| `Filled` events for B | **1** (tok=29946789355925612793) | (distribute path) |
| `Δ bidderTokens(B)` | **0** | 29946789355925612793 |
| `activeCount` after | 2 | — |

So lazy **does** assign take and emit `Filled` / bump global `sold`, but **never
credits** B’s token ledger. Leading suspect (still unfixed): `dustExit[i]`
excludes B from `uncW` after pre-clear dust refresh while `alive[]` stays true,
so water-fill records `takeAmt` + `emit Filled` without MasterChef harvest or
distribute. That is **not** the circularity hypothesis; fix requires a new
ruling (e.g. F1′: never emit/count take without a credit path).

### Push

Branch `lazy-flip` carries this forensic before any further ruling request
(`.cursorrules` STOP-push standing rule).

