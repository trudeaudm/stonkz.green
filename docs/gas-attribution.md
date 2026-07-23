# Task P — Clear-loop gas attribution

Status: **per-position write dominance REFUTED**. Task Q (H2+ lazy
materialization) **STOPPED** pending redesign. Numbers from
`contracts/test/GasAttribution.t.sol` (300 actives, 1 pos each, Foundry
`startStateDiffRecording` + `gasleft`).

## Gas: 7.35M avg vs ~32M single

| Measurement | Gas | Notes |
|-------------|-----|-------|
| Clear #1 after seed | **~31.4M** | ~1204 zero→nonzero SSTOREs |
| Clear #2 (warm, same test) | **~7.43M** | 0 zero→nonzero; mutate-only |
| 32-clear `poke` | **~234.7M** | avg **~7.33M**/clear |
| Seq 32×1-clear (first) | ~31.4M | matches clear #1 |
| Seq 32×1-clear (warm avg) | ~6.36M | same-test warm; slightly under poke32 avg |

**Discrepancy:** not setup inside the meter (seed is outside). First clear in a
tx pays **cold / zero→nonzero** SSTORE (~20k); later clears in the **same tx**
hit **warm** slots (~100–2.9k). Amortized poke32 ≈ warm per-clear cost.

## SSTORE / SLOAD split (per clear, 300 actives)

| | Clear #1 | Clear #2 warm |
|--|----------|---------------|
| SLOAD ops | ~22.8k | ~22.8k |
| SSTORE ops | ~4806 | ~4805 |
| Unique write slots | ~2106 | ~2105 |
| **Position** write ops | **600 (12%)** | **600 (12%)** |
| **Bidder** write ops | **4200 (87%)** | **4200 (87%)** |
| Global write ops | ~6 | ~5 |

Per address: **~14 bidder SSTOREs** (harvest `rewardDebt` + `_refreshWeightBasisOnly`×2
rewriting `activeBudget`/`activeSpent`/`activeCount`/`weight` + fill
`tokens`/`activeSpent`) vs **~2 position SSTOREs** (`tokens`+`spent`).

## Verdict

**Per-position writes do not dominate.** Per-address bidder bookkeeping does
(~87% of SSTOREs). Globals are noise. H2+ as scoped (lazy position credit) would
miss the primary cost center unless it also eliminates unconstrained
per-address refresh/harvest writes.

**STOP before Task Q redesign.** Ship Task R (`maxUniqueActives`) + this record.
