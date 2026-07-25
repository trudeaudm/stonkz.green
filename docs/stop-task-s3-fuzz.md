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

---

## G1 SET-DIFF — fuzz-001 block 10 (double-final-block hypothesis)

**Hypothesis:** lazy has exactly one extra **address** — exit-marked during clear 9,
re-admitted at 10 via channel-B — whose take ≈ 1.58e18 ≈ raised Δ 1.01e21.

**Verdict: REFUTED** (address set). Related position-mark drift **CONFIRMED**
(explains the same numbers). Per ruling: STOP — no improvising.

### Forensic
contracts/test/ForensicG1SetDiff.t.sol — eager/lazy lockstep, pre-clear actives
+ position statuses + Filled/AllIn logs for clears b=7..10.

### Address set at pre-clear b=10

| Path | nActive | Addresses |
|------|--------:|-----------|
| Eager | 1 | B only |
| Lazy | 1 | B only |

C marked AllIn(pos3) on **both** at b=9; absent at b=10 on both. **No extra address.
No channel-B re-admission of a b−1-marked address.**

### Position set for B (the real delta)

| Clear | Eager B positions | Lazy B positions | Notes |
|------:|-------------------|------------------|-------|
| post b=7 | pos6 → OutBudget (AllIn) | **pos6 still Active** (no AllIn B) | first drift |
| pre b=9 | 5 Active, 6 OutBudget, 7 Active (ac=2) | 5/6/7 all Active (ac=3) | |
| post b=9 | AllIn **pos5**; C AllIn pos3 | AllIn **pos6**; C AllIn pos3 | different pos exhausted |
| pre b=10 | 5 OutBudget, 6 OutBudget, **7 Active** (ac=1) | **5 Active**, 6 OutBudget, 7 Active (ac=2) | |
| post b=10 | fill B tok ≈ 3.288e18 | fill B tok ≈ 4.872e18 | |

### Numbers (hypothesis scale — confirmed as B's extra capacity)

| Signal | Eager | Lazy | Δ (lazy−eager) |
|--------|------:|-----:|---------------:|
| b=10 dSold | 3288084884037710767 | 4872253420497133901 | **1584168536459423134** ≈ 1.58e18 |
| b=10 dRaised | 2101698029323757559279 | 3114276478060449500505 | **1012578448736691942508** ≈ 1.01e21 |
| pre b=10 B headroom | ≈2.102e21 | ≈3.114e21 | ≈1.012e21 |

Price ≈ 639.186e18 WAD; extra tok × px ≈ extra raised. Match.

### Interpretation
Not double-final-block of an **address**. Lazy and eager **spend across B's
positions differently** (eager distribute vs lazy ACC/WRITE materialize), so
different positions hit OutBudget at b=7 and b=9. At b=10 the address set
matches; lazy's B still carries **pos5 Active** (eager marked it at b=9) →
higher weight/budget → oversell.

### Ruling needed (hypothesis refuted — no G1 fix applied)

| Opt | Action |
|-----|--------|
| **G1′** | Redefine participantsAt to **position-level** (or force mark-set
           equivalence): same positions Active at clear start; single source
           of truth for mark/spend so eager↔lazy position sets match |
| **G1″** | Keep address-level participantsAt as written; separately fix
           position spend/mark twin so OutBudget marks match per clear |
| **G1‴** | Other — human specifies after reading the table |

Task T / production green still blocked.

---

## HALT — G1''' production fuzz (post COMPOUND exact-track)

**Gate:** 	estFuzzVectors_seed4663_all200 after G1''' SIMPLE/COMPOUND.

### Green before this halt
| Item | Status |
|------|--------|
| G1 set-diff fuzz-001 b10 (1e21 oversell) | **Fixed** — position marks match; Δsold≈3 wei |
| EagerLazy canonical + size-tilt | Green (byte-identical aggregates) |
| EagerLazy fuzz-001 compound + marks | Green |
| Exhaustion (a)+(b), OrphanCredit | Green |
| WriteBudget ALL-SIMPLE warm=8; K-compound bound | Green |
| maxLivePositionsPerAddress guard | Green |
| exactWeiLedger canonical + size-tilt | Green |

### HALT — fuzz seed 4663 scenario **22** block **3** (raised)

**Vector:** 	est/vectors/fuzz/fuzz-022.json  
**Forensic:** contracts/test/ForensicFuzz022.t.sol

| b | lazyVsExp raised | eagerVsExp | lazyVsEager | nActive L | nActive E |
|--:|-----------------:|-----------:|------------:|----------:|----------:|
| 2 | 1 | 1 | 2 | — | — |
| **3** | **~3.95e20** | 1 | **~3.95e20** | **1** | **0** |

Eager book empty (nActive=0) — no further fill. Lazy still has **1 active** and oversells (~6.28e18 extra sold). Address-set drift: an address remains Active on lazy after eager exited it.

Not the fuzz-001 compound position-mark class (that is green). Suspect SIMPLE ACC dust/exit mark lag or COMPOUND→SIMPLE transition leaving weight live one clear too long.

### Ruling needed
| Opt | Action |
|-----|--------|
| **H1** | Set-diff fuzz-022 b2→b3 (who stays Active on lazy, mark block on eager) then fix exit timing |
| **H2** | Widen raised TOL (rejects — blinds 1e20-scale) |
| **H3** | Park production on eager until H1 |

**Human ruling:** execute **H1**; reject H2, H3.

---

## H1 SET-DIFF — fuzz-022 blocks 2→3 (ghost-active)

**Forensics:** `ForensicH1Ghost.t.sol`, `ForensicH1Ghost2.t.sol`  
**Only bidder:** A (solo). Not a multi-peer redistribution cascade.

### Per-address dump (material)

| Stage | Eager | Lazy |
|-------|-------|------|
| POST b1 | aspent=raised on pos1; pendU=0 | aspent=0; pendU≈7.90e20 (ACC) |
| PRE b2 (after 2nd placeBid) | pos1 spent≈7.90e20; pos2 OutPrice spent=**0** | pendU=0; **pos1 spent≈3.95e20; pos2 OutPrice spent≈3.95e20**; aspent≈7.90e20 |
| POST b2 | pos1 budLeft=**1**; dustAddr=1; nActive stays 1 until dust exit | pos1 budLeft≈3.95e20; dustAddr=0; aspent recomputed Active-only ≈5.90e20 |
| PRE b3 | dust → OutBudget; nActive→0 | still Active; ghost headroom≈3.95e20 → oversell |

**(b) Pre-step price operand — REFUTED**  
`lazy.price == eager.price` at b1–b3 clear starts; both step after full sells; pos2 OutPrice on both when `maxP < price`. Sweep / offer / take use the same post-step `price`. No clear-path pre-step read. **No `priceInForce` fix.**

**(a) Exhaust / ghost capacity within b2 — CONFIRMED (OutPrice orphan spent, not peer cascade)**  
1. Lazy ACC leaves fill USD in pending after b1.  
2. `placeBid` created the new position as **Active**, pushed it, then `_materialize` — pending split across pos1 **and** doomed pos2.  
3. Immediate OutPrice path did **not** reverse `activeSpent` (unlike `_priceOutBidder`).  
4. b2 budget-constraint WRITE + `_refreshWeightBasisOnly` recomputed `activeSpent` from **Active-only** positions → dropped orphan spend on OutPrice pos2 → **ghost headroom ≈3.95e20**.  
5. Eager never split pending (already distributed); pos2 spent stayed 0; b2 exhausts to 1 wei dust.

Fixpoint-law water-fill iteration mismatch inside one clear: **not the convict** (solo A; same constraint shape; divergence is ledger orphan before/after refresh). **No separate fixpoint iterator rewrite.** Permanent visibility: `EagerLazyEquivalence._assertActiveSpentLedger` + `test_equiv_fuzz022_ghostActive` + `RegressionH1Ghost`.

### Fix applied
`placeBid`: `_materialize` **before** creating the new position; priced-out bids born `OutPrice` (never Active → never receive pending split).

### H1 ladder (post-fix)
| Item | Status |
|------|--------|
| Exhaustion (a)+(b) | Green |
| EagerLazyEquivalence (incl. H1 ledger + fuzz-022 marks) | Green |
| WriteBudget ALL-SIMPLE warm=8; K-compound | Green |
| RegressionH1Ghost / OrphanCredit | Green |
| Full unit suite (excl. GasAttribution / Forensic) | Green |
| `testFuzzVectors_seed4663_all200` (production=lazy) | Green |
| Invariant campaign (512 runs, mid-auction claims) | Green (`exactWeiLedger` incl.) |

**(b) price operand** — stayed REFUTED; no `priceInForce` change.

Task T unblocked.

---

## Task T — storage packing + E1 retune (STOP on 2.5M target)

| Item | Status |
|------|--------|
| `Position` / `Bidder` ≤ 2 slots (`uint80` + flags) | Done |
| Warm ALL-SIMPLE @300 ≤ **2.5M** | **MISS** — **~6.09M** (~2.4×) |
| `maxClearsPerSync` default = floor(25M/measured) = **4** | Done |
| Assert `cap × measured ≤ 25M` | Green (`24344376 ≤ 25M`) |
| WriteBudget warm SSTOREs | **8** ≤ 16 Green |
| 200-vector + invariants under lazy | Green |

Residual: O(n) SLOAD + memory water-fill (packing saved ~2% on warm clear). Segment+heap (M5) needed for 2.5M. See `docs/gas-attribution.md`.
