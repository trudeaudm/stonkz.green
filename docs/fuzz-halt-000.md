# Forensic report: fuzz halt scenario 0 (seed 4663)

**Branch:** `fuzz-halt-000`  
**Scope:** evidence only — no changes to `StonkzAuction.sol` mechanism math, `sim-source.js`, or tolerances.  
**Halt:** `FUZZ HALT seed=4663 scenario=0 block=5 (raised)` (absolute TOL `1e18`).

---

## 3a. Scenario 0 params and bid schedule

Source: `contracts/test/vectors/fuzz/fuzz-000.json` (seed `4663`, index `0`).

| Param | Value |
|-------|-------|
| blocks | 12 |
| supply | `1000e18` |
| floorMcap | `35464237940032036405248` (~3.546e22) |
| threshold | `0` |
| baseStepBps | 0 |
| walletCapBps | 728 (7.28% of supply → **72.8 tokens**) |
| sizeBonusBps | 1988 |
| lpShareBps | 0 |
| holdbackBps | 1283 |
| kappaHundredths | 120 |

**Bid schedule (`actions`):**

| at | name | budget (WAD) | maxPrice (WAD) |
|----|------|--------------|----------------|
| 0 | A | 5624709926948417044480 | 30003102453300146176 |
| 0 | B | 5717919039265253097472 | 21802907391390146560 |
| 0 | B | 1706831138269044408320 | 314627274321441456128 |
| 0 | B | 2526754288112278962176 | 26499988916304515072 |
| 1 | A | 4719018498347140907008 | 35464237940032036864 |
| 1 | B | 2114270124481990885376 | 619911666478248493056 |
| 9 | B | 7210290315530728374272 | 469369166746535526400 |

Solidity floor price via `mulDiv(floorMcap, WAD, supply)` = `35464237940032036405` (459 wei below vector `blocks[*].price` = `35464237940032036864`).

---

## 3b. Side-by-side water-fill trace — block index 5

Schedule cursor / `auctionIndex == 5` (vector `blocks[5]`, hist `block: 6`).  
Reference: `STONKZ_TRACE_BLOCK=5` → `forensic-000-ref-trace.json`.  
Solidity: `test/Forensic000.t.sol` + `test/forensic/TracedWaterFill.sol` (mirror; production fill untouched).

Both implementations: **1 iteration**, then no actives left.

### Iteration 0

| Field | Reference (float) | Solidity (WAD) | Δ (approx) |
|-------|-------------------|----------------|------------|
| remainingBefore | 46.490666666666684 | 46490666666666666611 / 1e18 | ~1e-17 |
| totW | 17.793149586342288 | 17793149586342310480 / 1e18 | ~1e-17 |
| **A.weight** | 9.14211108829189 | 9142111088291900987 / 1e18 | ~1e-14 |
| **A.committedBasis** | 4719.018498347141 | 4719018498347140907008 / 1e18 | ~1e-15 |
| **A.share** | 23.886880575750105 | 23886880575750096701 / 1e18 | ~1e-14 |
| **A.capLeft** | 17.06394532324976 | 17063945323249775114 / 1e18 | ~1e-14 |
| **A.budLeft** (tok) | 77.32809028885502 | 77328090288855033800 / 1e18 | ~1e-14 |
| **A.take** | 17.06394532324976 | 17063945323249775114 / 1e18 | ~1e-14 |
| **A.constraintHit** | `cap` | `cap` | — |
| **B.weight** | 8.651038498050399 | 8651038498050409493 / 1e18 | ~1e-14 |
| **B.committedBasis** | 3821.1012627510354 | 3821101262751035293696 / 1e18 | ~1e-15 |
| **B.share** | 22.60378609091658 | 22603786090916569909 / 1e18 | ~1e-14 |
| **B.capLeft** | 12.309388010083552 | 12309388010083560584 / 1e18 | ~1e-14 |
| **B.budLeft** (tok) | 47.25458386660514 | 47254583866605143716 / 1e18 | ~1e-14 |
| **B.take** | 12.309388010083552 | 12309388010083560584 / 1e18 | ~1e-14 |
| **B.constraintHit** | `cap` | `cap` | — |
| remainingAfter | 17.11733333333337 | 17117333333333330913 / 1e18 | ~1e-14 |
| used (sold this clear) | 29.373333333333314 | 29373333333333335698 / 1e18 | ~1e-14 |

### Summary flags

| Flag | Reference | Solidity |
|------|-----------|----------|
| iterations | 1 | 1 (`itersDone`) |
| hitIterCap (8-bound w/ remaining>0) | **false** | **false** (0) |
| stoppedNoActives | **true** | implied (remaining>0, itersDone=1, hitIterCap=false) |
| constraintHits | **2** | **2** |

Live reference vs Solidity at this fill: **no field differs above `1e18` wei**; post-clear `raised` Δ(sol, live-ref) ≈ `1.56e5` wei (noise).

---

## 3c. FIRST DIVERGENT PRIMITIVE (halt oracle)

**Consumer halt compares Solidity to the stored JSON vector**, not live-ref to Solidity.

Blockwise Sol vs vector (`TOL=1e18`), wall-clock `vm.roll`:

| block idx | dPrice | dOffer | dRaised | over TOL? |
|-----------|--------|--------|---------|-----------|
| 0–4 | 459 | ≪1e18 | ≪1e18 | no |
| **5** | 459 | ≪1e18 | **2715328845389652309** | **yes — first halt field: `raised`** |

`raised` is the **symptom**. Underlying quantity at the same clear:

| Quantity | Solidity / live-ref | Stored vector `blocks[5]` | Δ |
|----------|---------------------|---------------------------|---|
| sold this block | `29373333333333335698` (~29.3733) | `29294664386349404160` (~29.2947) | **`78668946983907338` wei (~0.07867 tokens)** |
| take A (cap) | ~17.063945323249775 | fill A `17024687322452813824` (~17.0247) | ~0.0393 tokens |
| take B (cap) | ~12.309388010083561 | fill B `12269977063896590336` (~12.2700) | ~0.0394 tokens |
| raised (cum) | `5163593044068664500565` | `5160877715223274848256` | **`2715328845389652309`** |

**First divergent primitive (vs stored vector):** per-address **`take` at the wallet-cap boundary** in the single water-fill iteration of block 5 (both A and B `constraintHit=cap`).  
Those takes differ because **`capLeft = walletCap − tokBefore`** differs: cumulative `tokBefore` already drifted on the float→WAD vector-generation path vs WAD replay.  
`raised += take * price` then exceeds absolute `1e18`.

Live reference (WAD params → `Number`) vs Solidity: **not divergent** at this grain. The oracle mismatch is **stored float-generated vector vs WAD replay**.

---

## 3d. Eight-iteration bound & constraint hits

| Question | Answer |
|----------|--------|
| Did the **reference** hit the 8-iteration bound with remaining > 0 at block 5? | **No.** `hitIterCap: false`, `stoppedNoActives: true`, `iterations: 1`. |
| Did **Solidity** (mirror) hit the 8-iteration bound? | **No.** `hitIterCap: 0`, `itersDone: 1`, remaining > 0 because both addresses left the active set after cap hits. |
| Constraint-hit count (block 5) | **Reference: 2. Solidity: 2.** (A cap, B cap.) |

---

## 3e. Classification (exactly one)

**(B) float-vs-WAD rounding at a constraint boundary**

Evidence:

1. Live reference water-fill (WAD→Number params) ≈ Solidity fill (table 3b); not an algorithmic split between engine and contract.
2. Vectors are produced by float `createEngine(params)` then `toWad` on params/actions/blocks (`reference/fuzz-vectors.js`). Replaying the **rounded** WAD params does not reproduce the float trajectory that wrote the JSON.
3. First TOL breach is at block 5 where **both addresses bind on `walletCapTokens` (72.8e18)**; `take = min(share, capLeft, budLeft)` selects **`capLeft`**. Flipping addresses: **A and B**. Boundary quantity: **wallet cap (7.28% of launch supply)**.
4. Not (A): neither side exhausted 8 iterations.  
5. Not (C): weight basis, redistribution, cap denominator, and tilt agree between live-ref and Sol at the traced clear.

---

## 3f. Systemic scan (200 vectors, report-only)

Harness: `test/ForensicScanReport.t.sol` (no halt), wall-clock `vm.roll`, same `1e18` TOL as the consumer.  
Artifacts: `contracts/test/vectors/fuzz/scan-report.csv`, `scan-report-summary.json`.

| Metric | Value |
|--------|-------|
| Divergences | **151 / 200** (49 pass) |
| ctor-skip | 0 |
| First field mix | offered 91, raised 55, fill:A 3, fill:B 1, price 1 |
| Scenario 0 | block **5**, field **raised**, magnitude **2715328845389652309** (matches halt) |

**Flag correlation (among scenarios with that flag):**

| Flag | n with flag | diverge ∩ flag | rate |
|------|-------------|----------------|------|
| tight wallet cap (`walletCapBps < 2000`) | 37 | 25 | **67.6%** |
| sizeBonus > 0 | 162 | 122 | **75.3%** |
| multi-bid address | 164 | 131 | **79.9%** |
| overall | 200 | 151 | **75.5%** |

Multi-bid and sizeBonus rates sit near the base rate (most scenarios have them). **Tight caps are not required** for divergence (126/163 non-tight still diverge) but scenario 0 is tight-cap + cap-bound at the halt block. Many first failures are early (`firstBlock=0` for 77 rows), consistent with offer/price WAD round-trip, not only late cap events.

Full per-scenario table: `scan-report.csv` (`scenario,firstBlock,field,magnitude,tightCap,sizeBonus,multiBid`).

---

## 3g. Recommendation — **NOT APPLIED**

Proposal only; nothing below was merged into mechanism or tolerances.

1. **Vector oracle (preferred):** After drawing float params/actions, **re-run the engine on `fromWad(toWad(params))` / WAD→Number** and snapshot *that* trajectory — or generate bids/params in integer WAD from the start — so JSON matches Solidity’s input domain.
2. **Harness comparison:** Prefer **per-block Δ** (sold/raised/fills this clear) with a **relative** band (e.g. `max(1e18, ε · scale)`) instead of only cumulative absolute `1e18`, once the oracle is WAD-consistent.
3. **Do not** change Solidity fill math or reference mechanism formulas to chase float dump noise; live-ref and Sol already agree on scenario 0 block 5.
4. **Harness hygiene:** Use an explicit wall-clock counter for `vm.roll` (Foundry + via-ir can no-op `vm.roll(block.number+1)` after `placeBid`/`try`/`catch` in lean tests). Already applied in fuzz/scan harnesses on this branch only.

---

## Artifacts on this branch

| Path | Role |
|------|------|
| `reference/fuzz-vectors.js` | seed-4663 generator |
| `reference/engine.js` | opt-in `STONKZ_TRACE_BLOCK` patch (sim-source untouched) |
| `contracts/test/vectors/fuzz/` | 200 JSON vectors + scan CSV |
| `contracts/test/StonkzAuction.fuzz.t.sol` | halting consumer |
| `contracts/test/Forensic000.t.sol` | Sol block-5 trace |
| `contracts/test/forensic/TracedWaterFill.sol` | fill-path mirror + logs |
| `contracts/test/ForensicScanReport.t.sol` | report-only 200-scan |
| `docs/fuzz-halt-000.md` | this report |
