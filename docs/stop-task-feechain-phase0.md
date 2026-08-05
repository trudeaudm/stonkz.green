# STOP / PHASE 0 REPORT — FEECHAIN interface cleanup
**Branch:** `feat/m3-5-feechain`  
**Pinned canonical reference:** Uniswap `v4-core` @ `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (main tip as of 2026-08-03)  
**Status:** Phase 0 implementation complete on this commit; suite run below.

## Caller audit (before deletion)

| Symbol | Callers found |
|---|---|
| `convertTokenToPair` | `IPoolManager.sol` (decl), `MockPoolManager.sol` (impl), `StonkzFeeHook.sol` (2 call sites) |
| `crankConvert` | `StonkzFeeHook.sol` (def), `FeeLockerV2.crankMainFees`, `HookFees.t.sol` |
| Outside expected set | **NONE** |

## Divergences vs canonical `IPoolManager` @ pinned commit

### REMOVED this phase
| Ours | Canonical | Action |
|---|---|---|
| `convertTokenToPair(...)` | **absent** | **REMOVED** — invented for M4 best-effort conversion; docs/06 deletes the path |

### KEPT with justification (retire in later phases)
| Ours | Canonical | Justification |
|---|---|---|
| Entire minimal surface (no `unlock`/`take`/`settle`/…) | Full unlock/settle/ERC6909 surface | Provisional adapter until Phase 1 real v4 wiring |
| `ISwapHook.afterSwap(key, tokenIn, feeAmount)` | Real hooks via `IHooks` + deltas | Provisional seam; Phase 3 → BeforeSwapDelta |
| `setPoolHook` / `poolHook` | Hooks live in `PoolKey.hooks` | Provisional; Phase 1/2 attach via key |
| `syncToPrice` | **absent** | Settlement price sync (spec §8.7); real v4 path TBD in Phase 1 |
| `accrueFees` / `pendingFees` / `collectFees` | LP fees via position fee growth | FeeLocker side-compound mock; Phase 4 keeps side path |
| `PoolAlreadyInitialized` / `SyncBudgetExceeded` / `PriceNotSynced` | Different error set | Mock/settlement helpers |
| Nested `ModifyLiquidityParams` / `SwapParams` | Types in `PoolOperation.sol` | Shape-compatible subset |
| `getSlot0` / `isInitialized` | Different accessors | Mock convenience |

### Canonical members we lack (Phase 1 must confront)
`unlock`, `donate`, `sync`, `take`, `settle`/`settleFor`, `clear`, `mint`/`burn`, `updateDynamicLPFee`, plus `IProtocolFees` / ERC6909 / extsload. Integrating these is Phase 1 scope; if architectural choices arise beyond docs/06, STOP.

## Code changes this phase
- `IPoolManager.sol`: removed `convertTokenToPair`
- `MockPoolManager.sol`: removed conversion impl, `setConvertFail`, `_converting`, `Converted`
- `StonkzFeeHook.sol`: removed CONVERT_CAP / CRANK_COOLDOWN / crankConvert / accruedTokenFees / conversion try-catch; `afterSwap` splits pair fees only
- `FeeLockerV2.sol`: `crankMainFees` now reverts `MainFeeCrankRetired` (side compound untouched)

## Tests deleted (conversion feature)
| Test | Why deletion does not reduce surviving coverage |
|---|---|
| `test_C1_feeTakeConvertSplit_8020` | Exercised token→pair conversion; path gone. Pair split covered by `test_C1_pairDenominatedFee_directSplit` |
| `test_C1_bestEffort_forceFail_tradeSucceeds_accrue_thenCrank` | Conversion failure / crank only |
| `test_C1_receiverNeverGetsTokenFees` | Accrual-while-unconvertible only |
| `test_C1_crankCooldown` | `crankConvert` cooldown only |

## Tests added/adapted
- `test_C1_tokenDenominatedFee_ignoredUntilPhase3` — documents Phase 0 behavior (token feeAmount no-ops)
- `test_C1_gasOverhead_provisional` — now pays PAIR
- Pair-split + no-hook tests retained
- `CrossModelParity.test_C4_feeSplitParity_directAndManual` — adapted to pay PAIR (assertions unchanged); was calling conversion path via token-in

## Suite
`forge test`: **121 passed, 0 failed** (34 suites).

Gate 1 rulings (bounds, req #1 reword, side 30 bps, accrue-and-flush) already in docs/03+06+04 (gitignored).
