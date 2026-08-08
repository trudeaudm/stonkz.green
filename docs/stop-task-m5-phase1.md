# STOP / PHASE 1 REPORT — STONKZ-M5-LADDER auction core
**Branch:** `feat/m5-ladder`  
**Spec:** docs/09-ladder-spec.md §1–§2  
**Status:** Phase 1 complete. NO merge.

## Landed
- `LadderMath.sol` — `rungOf`, `rungPrice` (exact grid), `mmax` (circFrac=1), wallet liveBudget cap-room clamp
- `StonkzLadderAuction.sol` — time-derived periods via `elapsed * N / duration`, weight schedule (40/60 shallow/finale reused from `LadderWeights`), per-period clear, one-rung advance iff sold>0 and next rung ≤ Mmax, owner-settable `circExclusionVault` (default none)
- Off-chain lock: `scripts/ladder-ref-replay.mjs` — price path exact on vectors 02/03/04/05/07/10 before Solidity port
- Tests: `LadderMath.t.sol`, `LadderPhase1.t.sol`

## Differential (A5 + path prices exact)
| Vector | Result |
|---|---|
| 02-god-2p5k-at-bar | PASS — A5 + every path price exact |
| 04-4h-5k-at-bar | PASS |
| 05-daily-10k-at-bar | PASS |
| 07-road-40k-at-bar | PASS |

Also: liveBudget cap-room clamp (vector 10 shape), zero-sale non-advance / flat tail.

## Mmax identity
`circFrac = 1 ALWAYS` (FDV fallback). Vault hook = `circExclusionVault` (owner-settable, modularity rule); unused until docs/10.

## Gas note
Road at-bar clearAll ≈ 3.29B gas under current O(actives×periods) fill. Raised `foundry.toml` `gas_limit` to 5e9. Phase 4 will snapshot bid/claim/settle at 300 actives and must stay sane for *user* actions (not full 1000-period test replay).

## Suite
`forge test --match-path "test/ladder/*" --no-match-test test_P0_A1_to_A5_allTen`: **26 passed**.

## Next
Phase 2 — bid entry rules, per-address weight fills, A2 on all 10 vectors (hard pair: 03 oversub + 10 cap-binding).
