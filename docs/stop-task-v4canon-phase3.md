# STOP — V4-CANON Phase 3

**Branch:** `feat/v4-canon`  
**Status:** A1–A5 × 10 on Real **PASS**. Real Ladder **settle mint** **STOP**.

## Delivered

| Item | Status |
|---|---|
| A1–A5 × 10 vectors, byte-identical JSON | PASS on Mock (`LadderPhase3`) and Real (`LadderVectorsReal`) |
| Per-field tolerances (`LadderTolerance` / docs/09 §8) | unchanged — no widening |
| Dual-backend Express listing smoke | PASS (Phase 2) |
| Regression: LockStamp, SidePool switches, FeePhase3, FeeHookPhase1 | PASS (sampled) |

## STOP — Ladder cash/ask geometry under real PoolManager

**Symptom:** `LadderSettlement.settle` on V4Adapter for graduating vector 09 reverts (`OutOfFunds` / dust `liquidityDelta: 1`).

**Cause:** Mock `modifyLiquidity` ignores currency deltas. Real PM requires correct above/below-range composition. `LiquidityAmounts.getLiquidityForAmounts` returns 0 for cash-[floor,print] at print spot when `pairIs0` (native), then the `liq = 1` fallback mints a dust position that demands both currencies. ETH buffer exhausts on the second leg.

**Not a tolerance issue** — settlement never completes on Real; no output to compare. Widening tolerances would not fix this.

**Express** single-sided ask (`startTick + spacing` → max) **does** mint on Real (Phase 2). Ladder dual-leg cash+ask needs an explicit Real-PM geometry pass (orientation vs Uniswap token0/token1 rules) before Phase 4 fork drills that settle Ladder.

## Ruling requested

1. Accept A1–A5 Real proof + defer Ladder Real settle to a geometry task before Phase 4, **or**
2. Hold Phase 4 until Ladder settle is green on Real in-test PM.

`feat/launch-deploy` stays FROZEN until V4-CANON merges.
