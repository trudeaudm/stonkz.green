# STOP — post-quantization halt: scenario 5 (seed 4663)

Task I WAD-quantize-then-snapshot removed the original scenario-0 (B) float dump gap.  
Halting consumer then failed on **scenario 5, block 25, field `dFill=B`** (per-block policy).  
This is **not** classification (B). Human review required before Task J/K.

---

## 3a. Scenario 5 params and bid schedule

Source: `contracts/test/vectors/fuzz/fuzz-005.json` (`quantized: true`).

| Param | Value |
|-------|-------|
| blocks | 29 |
| supply | `1000e18` |
| floorMcap | `32277618112508209397760` |
| threshold | 0 |
| baseStepBps | 12 |
| walletCapBps | 2507 → **250.7 tokens** |
| sizeBonusBps | 1785 (α > 0) |
| lpShareBps | 6932 |
| holdbackBps | 1589 |
| kappaHundredths | 199 |

**Bids:**

| at | name | budget (WAD) | maxPrice (WAD) |
|----|------|--------------|----------------|
| 0 | A | 3128659968166611910656 | 32307228140275724288 |
| 0 | B | 3865322965285740740608 | 32278735676475662336 |
| 0 | C | 3465801850317511852032 | 32319774664599011328 |
| 1 | B | 2450163918202743029760 | 478935954390657007616 |
| 3 | A | 2617176912745926754304 | 32316667248103682048 |
| 8 | C | 2311722055738791821312 | 34376985635821703168 |
| 9 | B | 2660058993513229975552 | 1e27 |
| 15 | B | 4042034080817829904384 | 23690485943231107072 |
| 20 | A | 1275631184489466298368 | 29893752139617857536 |
| 20 | B | 5668359750236850094080 | 321791498007177396224 |
| 25 | B | 1158202112352009846784 | 32282219008087724032 |
| 25 | C | 5252962674589361504256 | 1e27 |

---

## 3b. Side-by-side water-fill — block index 25

Pre-clear (live quantized ref ≈ Sol cumulatives under 1e18): sold ≈ 300.26, raised ≈ 9881.8, offered ≈ 43.13, price ≈ 33.260.

### Reference (`STONKZ_TRACE_BLOCK=25`) — 1 iteration, remaining → 0

| Field | B | C |
|-------|---|---|
| weight | 7.751546078869811 | 7.613009032641255 |
| committedBasis (bud) | 5668.35975023685 | 5252.962674589361 |
| share | 21.759177235943937 | 21.37029324919341 |
| capLeft | 22.384014369789213 | 179.04835118160048 |
| budLeft | 98.25849192160442 | 157.93624653534056 |
| take | **21.759177235943937** | **21.37029324919341** |
| constraintHit | none | none |

`hitIterCap: false`, `constraintHits: 0`, `iterations: 1`.

### Solidity (`Forensic005Trace` + `TracedWaterFill`) — 2 iterations

Pre-bidder B: `activeCount=1`, `activeBudget=10778582661952823099392` (~10778.58), `weight=9026566295578809755` (~9.027), `tokens≈228.316`.  
Pre-bidder C: `activeCount=1`, `activeBudget≈5252.96`, `weight≈7.613`.

| Field | B (iter 0) | C (iter 0) | C (iter 1) |
|-------|------------|------------|------------|
| weight | 9.02656629557881 | 7.613009032641247 | 7.613009032641247 |
| committedBasis | **10778.58** | 5252.96 | 5252.96 |
| share | 23.396692340281412 | 19.732778144855928 | 1.01267797049201 |
| capLeft | 22.384014369789402 | 179.048… | 159.316… |
| take | **22.384014369789402** | 19.732778144855928 | 1.01267797049201 |
| constraintHit | **cap (1)** | none | none |

`hitIterCap: 0`, `itersDone: 2`, `constraintHits: 1`.  
B fill Δ(sol, vec) = `624837133845449951` wei (~0.625 tokens) > per-block tol `1e12`.

---

## 3c. FIRST DIVERGENT PRIMITIVE

**`B.weight` / `B.committedBasis` (activeBudget) entering the block-25 clear.**

| | Reference | Solidity | Δ |
|--|-----------|----------|---|
| B.committedBasis | ~5668.36 USD | ~10778.58 USD | **~5110 USD** |
| B.weight | ~7.7515 | ~9.0266 | **~1.275** |
| B.share | ~21.759 | ~23.397 | ~1.638 tokens |
| B.take | ~21.759 (unconstrained) | ~22.384 (**cap-bound**) | **~0.625 tokens** |

Symptom `dFill:B` is downstream: larger Sol weight → share ≥ capLeft → cap hit → take = capLeft; remainder redistributes to C on iter 1.

Not isolated as mere `take`/`raised` rounding: the **inputs to share** already disagree.

---

## 3d. Eight-iteration bound & constraint hits

| | Reference | Solidity |
|--|-----------|----------|
| hitIterCap (8-bound w/ remaining>0) | **false** | **false** |
| iterations | 1 | 2 |
| constraintHits | **0** | **1** (B cap) |

---

## 3e. Classification (exactly one)

**(C) genuine algorithmic mismatch — weight basis / activeBudget maintenance on multi-position addresses**

Evidence:

1. Same quantized WAD params/actions; live ref trajectory matches stored vector at this block (fill B Δ ~1e-14). Solidity does not.
2. Size tilt α > 0 (`sizeBonusBps=1785`); weight = `committed^α`. Divergent `activeBudget` ⇒ divergent weights.
3. Ref water-fill is per-address with `bud = Σ active position budgets` (sim-source). Sol `bidders[B].activeBudget` at pre-clear is ~10778 with `activeCount=1`, inconsistent with ref’s ~5668 basis for the same clear.
4. Likely locus (for review, **not patched**): Solidity paths that mark a position `OutBudget` / price-out decrement `activeCount` but leave `activeBudget` stale until a full refresh (`_exhaustBudgets` refresh exists but may not run on every exit path / `_distributeToPositions` only decrements count).

Not (A): neither side hit the 8-iter cap.  
Not (B): quantization + cliff alignment already applied; ref↔vector agree; Sol↔ref disagree on weight inputs.

---

## Task I status

| Gate | Status |
|------|--------|
| Quantize-then-snapshot oracle | Done (`reference/wad-vector.js`, fuzz + gen-vectors) |
| Dual comparison policy | In consumers (abs 1e18 + per-block max(1e12, 1e-9·scale)) |
| 200/200 halting consumer | **FAIL — stop at scenario 5** |
| engine.test.js 19/19 | Pass |
| Tasks J, K | **Not started** (blocked) |

## Recommendation (NOT APPLIED)

Inspect Solidity `activeBudget` / `_reweight` vs reference `activePos` sum when positions flip `out_budget` mid-auction with α > 0 and multi-bid addresses. Fix only after human confirms which side is spec-correct (reference still wins by default).
