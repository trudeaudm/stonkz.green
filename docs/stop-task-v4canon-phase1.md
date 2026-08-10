# STOP — V4-CANON Phase 1

**Branch:** `feat/v4-canon`  
**Ruling inputs:** real-v4-is-a-launch-gate; hook mine `0x4663`+`0x088` accepted; ledger wording accepted.

## Delivered

| Item | Status |
|---|---|
| `StonkzFeeHook` implements canonical `IHooks` | done |
| `beforeSwap` + BeforeSwapDelta pair-side take | done (ExactInHookFeeHarness semantics + exact-out) |
| Accrue-and-flush + per-pool stamps | unchanged |
| `setPoolHook` removed from register | done — binds via `PoolKey.hooks` |
| Mock `ISwapHook.afterSwap` retained | dual-backend fast path |
| Address flags `0x088` | `HOOK_FLAGS`; `validateHookAddress` |
| Production mine target `0x4663` top + `0x088` low | `HookVanity.sol` + `scripts/hook-vanity-mine.mjs` |
| Tests: CREATE2 to flag-valid address | `FeeHookPhase1.t.sol` (6/6) |
| Exact-in + exact-out 100 bps under real PM | pass |
| Hostile receiver + trade-never-reverts under real PM | pass |
| Mock afterSwap regression (`HookFees`, `FeePhase3`, `MockVsReal`) | pass |

## Canary / proof notes

- Tests mine **flags only** (~2^14) via CREATE2 so constructor storage runs. Production miner adds `0x4663` prefix (~2^30).
- BeforeSwapDelta currency sort matches v4 `DeltaReturningHook`: `(zeroForOne == exactIn) ? (c0,c1) : (c1,c0)`. Fee always taken in `pair` on whichever side pair sits.
- Mock reads `key.hooks` first (falls back to legacy `setPoolHook` map).

## STOP conditions checked

- Hook mining infeasibility: **not triggered** — flag mine hits in tests; full prefix+flags remains offline miner job.
- No vector tolerance changes (Phase 3).

## Next

Phase 2 — DirectListing + LadderSettlement + FeeLockerV2 onto `V4Adapter`; retire `StonkzLiquidityStrategy` if unused.
