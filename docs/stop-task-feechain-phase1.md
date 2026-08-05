# FEECHAIN PHASE 1 REPORT — real v4 + honest mock + canary
**Branch:** `feat/m3-5-feechain`  
**Status:** Phase 1 complete; suite green.

## Pins (recorded in `contracts/foundry.toml` comments + remappings)
| Dependency | Commit |
|---|---|
| `v4-core` | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` |
| `v4-periphery` | `545a5d2a87228167edde48f3b9eda122d1e3c4d6` |

Remappings force our `v4-core` pin over periphery's nested submodule
(`59d3ecf…`). `evm_version = "cancun"` required for real PoolManager (transient storage).

## Mock honesty (docs/06 vacuity)
`MockPoolManager.swap`:
- `key.fee == 0` + hook attached → `feeAmount = absAmt * hookFeeBps / 10_000`
  (default `hookFeeBps = 100` stamped on `setPoolHook`; Gate 1 default).
- `key.fee != 0` → legacy ppm path (`key.fee` / `feePpmOverride`) unchanged for
  side-pool / existing HookFees tests at fee=3000.

## Canary (non-negotiable)
`test/FeeCanary.t.sol::test_canary_fee0_hookAttached_protocolRevenueGtZero`
- fee=0 main pool, hook attached, PAIR exact-in → treasury proceeds > 0
  (assertEq 2 ether = 20% of 100 bps on 1000 ether).

### Detached / attached demonstration
| Run | Command | Result |
|---|---|---|
| Attached | `forge test --match-test test_canary_fee0_hookAttached_protocolRevenueGtZero` | **PASS** |
| Detached | `$env:CANARY_DETACH='true'; forge test --match-test test_canary_fee0_hookAttached_protocolRevenueGtZero` | **FAIL** `vacuity: fee take bypassed on fee=0 pool: 0 <= 0` |
| Reattach | unset `CANARY_DETACH`; re-run | **PASS** |

## Differential (mock vs real)
`test/MockVsRealV4Fees.t.sol`:
- Mock path: StonkzFeeHook + MockPoolManager fee=0 @ 100 bps → accrued fee total.
- Real path: canonical `PoolManager` + etched `ExactInHookFeeHarness`
  (`BEFORE_SWAP` + `BEFORE_SWAP_RETURNS_DELTA`) taking `amountIn * 100 / 10_000`
  of specified currency via `BeforeSwapDelta`.
- `test_diff_mockVsReal_exactIn_100bps` — identical fee amounts (amountIn=1000).
- `testFuzz_diff_mockVsReal_exactIn_100bps` — fuzz-halt mock vs formula.

## Provisional surface (unchanged; later phases)
Production still uses our minimal `IPoolManager` / `syncToPrice` / `setPoolHook`
adapter. Real unlock/settle wiring for LiquidityStrategy / DirectListing is
Phase 2–4 scope. Phase 1 proves: (1) libs pinned and compile, (2) mock is not
vacuous at fee=0, (3) fee formula matches a real-v4 BeforeSwapDelta take harness.

## Suite
`forge test`: **124 passed, 0 failed** (36 suites). (+3 vs Phase 0: canary + 2 differential).
