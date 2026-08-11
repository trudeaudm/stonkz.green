# STOP — PREDEPLOY-REFIT Phase 3a (park cut) + Phase 2 (accumulator v2)

**Branch:** `feat/predeploy-refit`  
**Ruling:** PARK-GATE **A** — park cut first, then accumulator v2 clean.

## Phase 3a — park cut

| Change | Detail |
|---|---|
| `StonkzDirectListing` | `createSidePool=true` && `sideTokenRef==0` → revert `SideTokenRefUnset` (loud). Park call site **removed**. |
| `createSidePool=false` | Unchanged — no sideTokenRef required. |
| `deploySidePool` | No `releaseSidePoolTokens`; requires non-zero `sideTokenRef`. |
| `SidePoolParked` event | Removed from DirectListing. |
| Legacy strategy | Park branch removed — requires live side token to deploy side (compile-safe vs accumulator). |
| Express / DirectListing tests | Configure etched stand-in `sideTokenRef` (production semantics). |

### ForkCanon config change (explicit)

| Before | After |
|---|---|
| `ExpressFactory(..., sideTokenRef=address(0))` + `setRefPrice(0, PAIR, …)` (park path) | `ExpressFactory(..., sideTokenRef=address(stonkz))` — production birth state |
| Refprice drill keyed `(0, PAIR)` | Refprice drill keyed `(stonkz, PAIR)` |

A fork path that depended on unset-ref park was testing a state production never inhabits.

### Live park/strategy callers after cut

| Asset | Status |
|---|---|
| `src/StonkzDirectListing` | **cleared** |
| `src/BuybackAccumulator` | **cleared** (Phase 2) |
| `legacy/StonkzLiquidityStrategy` | **cleared** (no park calls) |
| `LadderSettlement` `SidePoolParked` event | Soft emit when settlement `sideTokenRef==0` — **does not** call accumulator park. Left for Phase 3/ops clarity if you want loud-unset there too. |

## Phase 2 — BuybackAccumulator v2

| Feature | Launch default / bound |
|---|---|
| Manual fund | `receive` / `fundETH` / `fundERC20` / `receiveFees` / `receiveCarve` |
| `crank(pctBps)` | owner **or** settable `keeper` |
| Band | owner `[minPctBps, maxPctBps]`; launch 100–300; hard `[1, 2000]` |
| Interval | `minCrankInterval`; launch 1 hour; `CrankTooSoon` |
| Slippage | `maxSlippageBps`; launch 100; hard cap 1000; vs pre-swap pool spot |
| Executor | settable `IBuyExecutor` (Phase 4 wires real V4 path) |
| Burn | `sideTokenRef` → `0x…dEaD` atomically; `Cranked(amountIn, amountOut, burned, price, caller)` |
| Park/strategy | **RETIRED** — zero surface (`test_parkSurface_gone`) |
| Hostile keeper | fuzz + fixed: extractable per interval ≤ `maxPctBps` of remaining |

## Tests (sampled)

- BuybackAccumulatorTest 8/8 (incl. fuzz hostile keeper)
- DirectListing 8/8 (incl. `SideTokenRefUnset`)
- SidePoolSwitches / RefPrice / SettableRefs / DeployControls / SwitchDrill / LockStamp — green
- CrossModelParity fixed to set sideTokenRef
- vectors — **untouched** (RIDER B)

## Still open (Phase 3 remainder + 4)

- FeeLocker V1 → `contracts/legacy/` (ruled)
- Optional: LadderSettlement loud-unset instead of `SidePoolParked` emit
- Phase 4: Deploy.s.sol wiring, runbook, fork fund→crank→burn, `docs/19-refit-report.md`

**Held:** `feat/launch-deploy` @ `3fcdf74`. No merge / no broadcast.
