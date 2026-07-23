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


---

## RESOLVED — F1' two-channel crediting law

**Ruling:** F1' accepted (orphan = take without credit). Circularity remains REFUTED.

### Law
Per clear `b`, every participating address is in exactly one channel:
- **ACC**: unconstrained, no exit mark → global `perWeight` delta over `uncW` only (zero per-bidder writes).
- **WRITE**: constraint-hit this clear OR exit-marked-and-live (dust/OutBudget/cap/price-out) → block-`b` take/cost written explicitly. Orphan fix: dustExit with `takeAmt>0` and no Active positions → direct credit onto lowest `positionId`.

No promote-all (would destroy WriteBudget). Mixed clears keep both channels; water-fill `sold`/`raised` stay the aggregate oracle.

### Reconciliation
`soldThisClear` / `spentThisClear` vs `Σ WRITE + mulDiv(accDelta, uncW, …)`:
- Pure ACC: revert in test profile (chainid 31337) if gap > `nA` wei; emit `CreditChannelMismatch`.
- Mixed WRITE: emit only (distribute floors below water-fill).

### Conservation (post-remeasure)
- Token off-by-1: `tokensAccounted` now counts unswept residue mid-auction (dropped `done` gate). Exact after `materializeAll`.
- Size-tilt `Σspent` vs `raised` Δ=109: under-credit from ACC harvest + exit WRITE / `budLeft` truncations. Swept as `settleSpentDust` at settle. Bound `D = weightDustAccum + P` with `weightDustAccum = Σ_clears Σ_takers 4×ceil(w/WAD)` (single SSTORE per clear). Assert `settleSpentDust ≤ D`.

### Regression
`test/RegressionOrphanCredit.t.sol` — fuzz-005 block 24: `ΔbidderTokens(B) == Filled` wei-exact.

### WriteBudget
Warm unconstrained: **8** SSTOREs (was 7; +1 `weightDustAccum`). Bound remains ≤16.


---

## HALT — F1' production fuzz (post two-channel)

**Gate:** 	estFuzzVectors_seed4663_all200 after F1' two-channel + conservation sweep.

### Green before this halt
| Item | Status |
|------|--------|
| Exhaustion (a)+(b) | Green |
| RegressionOrphanCredit (fuzz-005 b24) | Green — Δtok = Filled wei-exact |
| EagerLazyEquivalence (canonical + fuzz20 + size-tilt) | Green |
| WriteBudget warm | **8** SSTOREs ≤ 16 |
| exactWeiLedger canonical + size-tilt | Green (settleSpentDust + spentAccounted) |
| invariant_exactWeiLedger (often) | Intermittent over-account +1 (see below) |

### HALT — fuzz seed 4663 scenario **1** block **10** (raised)

**Vector:** 	est/vectors/fuzz/fuzz-001.json (.blocks[10] = engine block 11).

**Lockstep** (	est/ForensicFuzz001Raised.t.sol):

| clear b | lazyVsExp raised | eagerVsExp | lazyVsEager raised | lazySold | eagerSold |
|--------:|-----------------:|-----------:|-------------------:|---------:|----------:|
| 8 | ~8.7e5 | ~8.7e5 | 1921 | match-class | match-class |
| 9 | ~1.9e6 | ~1.9e6 | 1282 | match-class | match-class |
| **10** | **~1.01e21** | ~5.9e5 | **~1.01e21** | **4.350e19** | **4.192e19** |

At b=10 lazy **dRaised ≈ 3.11e21** vs eager/oracle **≈ 2.10e21**. Lazy also **over-sells** (~1.58e18 extra cumulative sold vs eager). Not a dust-bound issue — aggregate water-fill / exit-set divergence.

Eager stays within TOL of the vector; lazy does not. So this is **lazy-path specific**, not oracle/vector drift.

### Related — invariant over-account

invariant_exactWeiLedger: 	okensAccounted == sold + 1 on a shrunk mid-auction claim/poke sequence. Opposite polarity from the pre-F1' under-account (sold = accounted + 1). Likely related to channel / materialize ordering; not widened.

### Ruling needed

| Opt | Action |
|-----|--------|
| **G1** | Trace b=10 exit set (who stays Active / dustExit / WRITE) vs eager; fix lazy alive/credit so sold/raised match eager byte-class |
| **G2** | Treat raised TOL failure as known α≠0 floor until G1 (rejects: blinds 1e21 bug) |
| **G3** | Keep CI on eager for 200-vector until G1 |

**Task T** still blocked.

### Push
Branch lazy-flip — this forensic + F1' implementation commits before ruling.
