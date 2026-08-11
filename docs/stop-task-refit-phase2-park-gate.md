# STOP — PREDEPLOY-REFIT Phase 2 gate (park live caller)

**Branch:** `feat/predeploy-refit` @ `7bea5a4` (Phase 1 pushed)  
**Held:** `feat/launch-deploy` @ `3fcdf74`

## Phase 1 done

Settable refs + `sideTokenRef` rename + `refPriceWad(side, pair)` rekey. Tests green; vectors byte-identical. See `docs/stop-task-refit-phase1.md`.

## Phase 2 blocked — ruling 2

> RETIRE the park/strategy path … **If anything live still calls it, STOP and report rather than folding.**

### Live callers of park / strategy (still on this branch)

| Caller | Path | Behavior |
|---|---|---|
| **`StonkzDirectListing` ctor** | `contracts/src/StonkzDirectListing.sol` ~L219–224 | When `sideTokenRef_ == 0` and `sidePoolTokens > 0`: `accumulator.parkSidePoolTokens(sidePoolTokens)` |
| `StonkzLiquidityStrategy` | `contracts/legacy/` | Legacy only — not Express/Ladder production path |
| Tests | `BuybackAccumulator.t.sol`, strategy suites | `setStrategy` / `parkSidePoolTokens` |

Express factory can still stamp `sideTokenRef = 0` (pre-genesis). ForkCanon intentionally uses that park path.

### Consequence

Phase 2 BuybackAccumulator v2 **cannot** drop `parkSidePoolTokens` / `setStrategy` / `releaseSidePoolTokens` without a compile break or silent fold in DirectListing — both forbidden without a further ruling.

Phase 3 already scoped “park-path retirement,” but Phase 2 rebuild wants those functions gone first.

## Ruling ask (pick one)

**A (recommended):** Authorize **Phase 3 park cut first** on Express:
- When `sideTokenRef == 0` and side mass would park → **revert** `SideTokenRefUnset` (or skip side split entirely only if `createSidePool=false`).
- Remove `park*` / `setStrategy` / `release*` from accumulator in the same or immediately following Phase 2 commit.
- Update ForkCanon / tests that relied on park.

**B:** Authorize **temporary fold** — Phase 2 ships crank/keeper/slippage/burn while leaving park stubs until a later Phase 3 commit (contradicts “retire / don’t fold”).

**C:** Other — specify Express pre-genesis behavior without parking.

No Phase 2 code until you pick. No merge / no broadcast.
