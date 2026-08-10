# STOP — V4-CANON Phase 5 (reconciliation + merge ruling)

**Branch:** `feat/v4-canon` @ `9c46698`+  
**Remote:** `stonkz.green`  
**launch-deploy:** remains **FROZEN** until this merges.

## Delivered

| Item | Status |
|---|---|
| `docs/18-v4canon-report.md` | written (gitignored working doc) |
| Ledger correction in local `docs/03` | appended [D] 2026-08-10 V4-CANON |
| FEECHAIN verbatim honesty wording | in ledger |
| protocolFeeController reopened monitored | in ledger + Phase 4 probe |
| Phases 0–4 pushed | yes |

## Verbatim ledger entries (for review)

> FEECHAIN proved the 100 bps exact-in fee formula against a real in-test PoolManager BeforeSwapDelta harness; it did not ship production unlock/BeforeSwapDelta integration or bind to Robinhood's deployed PoolManager.

> protocolFeeController REOPENED as monitored: live, owned; main pools immune (LP-fee-0); side-pool exposure ≤5 bp.

## STATE FOR MERGE RULING

**ASK:** Merge `feat/v4-canon` → `main`?

On YES:
1. Merge (David GO).
2. Unfreeze `feat/launch-deploy`.
3. Re-point launch-deploy deploy script / address book to V4Adapter + mined hook + singleton PM.

On NO: state what remains.

## Tip of branch

```
9c46698 feat(v4-canon): Phase 4 — fork gate vs RH singleton PM
6839276 fix(v4-canon): Ladder Real settle — orientation-correct §7 construction
… Phase 0–3 …
```

file() gas **29,274,312** / 32M. A1–A5 Real green. Fork drills green.
