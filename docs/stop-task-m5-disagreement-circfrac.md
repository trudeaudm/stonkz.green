# STOP — circFrac: docs/09 / prompt vs vector 08
**Branch:** `feat/m5-ladder`  
**Status:** HALTED mid Phase 2. Phase 0–1 already pushed. Do not improvise.

## Conflict
| Source | Statement |
|---|---|
| docs/09 §1 | `circFrac = 1 - holdbackPct` when delivery == LOCK (vault-verified), **else 1**. **UNTIL vault live: circFrac = 1 ALWAYS (FDV fallback, ruled).** |
| docs/03 2026-08-08 | Gate fallback: until vault live and lock verifiable, graduation uses FDV (no circulating exclusion). |
| M5 prompt Phase 1 | `Mmax identity with circFrac = 1 ALWAYS` (vault hook owner-settable, default no exclusion). |
| **Vector 08** (`08-locked-holdback-60.json`) | `holdbackDelivery: "vest"`, `holdbackPct: 60`. Clearing path and `mcapCirculating` **only** match when `circFrac = 0.4` in the Mmax denominator. |

## Evidence (vector 08)
- `floorMcap=10000`, `lpHealthTarget=0.35`, `lpShare=0.91`, total bid capital ≈ liveBudget at open
- Mmax with `circFrac=1`: ≈ \$62,468 → clear price path tops ~\$0.000062 — **mismatches** vector (`clearingPrice=0.000141`, `mcapFDV=141000`)
- Mmax with `circFrac=0.4`: ≈ \$141,170 → rung-capped at \$141,000 / 1e9 = **0.000141** — **matches**
- `outputs.mcapCirculating = 56400 = mcapFDV × 0.4` — sim applied circulating exclusion for vest

Spent/refund still match under `circFrac=1` (money conservation); tokens and price path do not (avg fill price too low → token amounts ~2.26× expected).

## Not prompt↔docs/09 disagreement
Prompt and docs/09 agree on FDV/`circFrac=1` until vault. The **vectors** (authoritative differential inputs per docs/09 §8 and the M5 prompt) disagree with that prose for vest holdback.

## Options for David ruling
1. **Match vectors:** apply `circFrac = 1 - holdbackPct` for `vest`/`lock`/`LOCK` in Mmax (and circulating mcap for lpHealth) even before vault — treat "ALWAYS 1" as superseded by vector truth.
2. **Match docs/03 fallback:** keep `circFrac=1` until vault; **exclude or re-pin vector 08** (and any vest/lock path expectations) from differential green — document as sim/lab drift.
3. **Narrow carve:** `circFrac=1` on-chain until vault, but harness compares vector 08 under a declared sim-only circFrac mode (contract still FDV) — weakens "contract must replay the vectors."

## Ask
Please rule 1 / 2 / 3 (or another). Phase 2 (A2 on all 10) is blocked on 08 (and possibly 09 — `instant` 20% holdback; price path matched under circFrac=1 in spot checks but token rel ~8e-4).

## Already green (unaffected)
- Phase 0 harness/canary/tolerances
- Phase 1 A5 + path exact on at-bar **02/04/05/07** (no holdback)
- Vector 10 cap-binding (no holdback) — fill spent exact in JS ref
