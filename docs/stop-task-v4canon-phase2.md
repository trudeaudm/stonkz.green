# STOP — V4-CANON Phase 2

**Branch:** `feat/v4-canon`  
**Depends on:** Phase 0 adapter, Phase 1 hook.

## Delivered

| Item | Status |
|---|---|
| `FeeLockerV2` → `pokeCollect` + stored ticks/salt | done |
| `IPoolManager.pokeCollect` + Mock impl | done |
| DirectListing / LadderSettlement unlock via adapter | done (IPoolManager = V4Adapter) |
| ERC20 approve-to-PM before modifyLiquidity | done |
| Native ETH: payable constructor / `list` + value forward | done |
| Main range strictly above spot (`startTick + spacing`) | done (real PM single-sided) |
| `PoolKey.hooks = hook` (no setPoolHook) | preserved |
| `StonkzLiquidityStrategy` → `contracts/legacy/` | done (tests + legacy auction re-pointed) |
| Dual-backend listing smoke | `ListingAdapterPhase2` Mock+Real pass |

## Geometry note (real PM)

Mock ignored cash deltas. Real PM showed in-range `[startTick, max]` demanded ETH. Lower tick is now `startTick + TICK_SPACING` so the ask range sits strictly above open. Native pair still forwards an ETH buffer for settle dust; adapter refunds remainder.

## LiquidityStrategy retirement

Nothing in the official Express/Ladder manifest imports it. Live path is DirectListing + LadderSettlement. Moved to `contracts/legacy/` with a header note; FEECHAIN/seam tests keep importing it from there.

## STOP conditions

- No vector tolerance changes.
- Docs ambiguity: none blocking; ETH buffer + above-spot tick are implementation of documented single-sided ask.

## Next

Phase 3 — A1–A5 × 10 vectors on **real** backend; full regression both backends.
