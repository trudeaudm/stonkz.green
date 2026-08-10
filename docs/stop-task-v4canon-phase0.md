# STOP — V4-CANON Phase 0 (adapter + dual-backend + canary)

**Branch:** `feat/v4-canon` (from main @ `594a17f`)  
**Ruling input:** real-v4-is-a-launch-gate + V4-GAP-ANALYSIS  
**Remote:** stonkz.green — ABORT if stonkz-site  
**launch-deploy:** FROZEN (no commits)

## Delivered

| Artifact | Role |
|---|---|
| `contracts/src/v4/V4Adapter.sol` | Unlock callback; implements our `IPoolManager` against canonical PM |
| `contracts/test/V4DualBackend.sol` | Mock \| Real (Deployers) test base |
| `contracts/test/V4AdapterPhase0.t.sol` | Init/StateLibrary, netting green, **canary** red→green, mock-seam reverts |
| `IPoolManager` / `MockPoolManager` | `modifyLiquidity`/`swap`/`syncToPrice` marked `payable` (ETH settle) |

## Adapter surface

- `initialize` — passthrough (no unlock)
- `modifyLiquidity` — unlock + settle/take (ERC20 + native ETH)
- `swap` — unlock + settle/take
- `syncToPrice` — unlock + exact-in swap toward target; **budget semantics ours** (`SyncBudgetExceeded`)
- `isInitialized` / `getSlot0` — `StateLibrary` (`sqrtPriceX96 != 0`)
- `pokeCollect` — 0-delta modifyLiquidity → take fees (FeeLocker Phase 2 entry)
- `setPoolHook` / `accrueFees` / `collectFees(id,pos)` — `MockSeamRetired` (Phase 1/2)

## Canary (vacuity guard)

`setBreakNetting(true)` → `modifyLiquidity` reverts (CurrencyNotSettled).  
`setBreakNetting(false)` → same call succeeds.  
Evidence: `test_P0_canary_breakNetting_redThenGreen` PASS.

## Tests

`forge test --match-contract V4AdapterPhase0` — 4/4 green.

## Next

Phase 1 — StonkzFeeHook as real `IHooks` (beforeSwap + BeforeSwapDelta); miner flags `0x4663`+`0x088`.
