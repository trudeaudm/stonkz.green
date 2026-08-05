# FEECHAIN PHASE 4 REPORT — retire FeeLocker main route + E2E
**Branch:** `feat/m3-5-feechain`  
**Status:** Phase 4 complete; suite green. Side-pool compounding UNTOUCHED.

## Scope (reduced by Phase 2)
Auction hook wiring already done in Phase 2. This phase:
1. Retire `FeeLocker.crankMainFees` (pair-fees → BuybackAccumulator).
2. Sever BuybackAccumulator from every automatic fee path; keep as manual DCA.
3. Confirm `protocolFeeBps` stamped from mutable factory default (cap 4000).
4. E2E: settle → keys → swaps both ways → flush → side compound.

## FeeLocker main route
- `FeeLocker.crankMainFees` now reverts `MainFeeCrankRetired` (mirrors FeeLockerV2).
- `crankSideCompound` **byte-identical behavior** — not modified in logic.
- `BuybackAccumulator` constructor arg retained on FeeLocker for deploy/ABI compatibility;
  never invoked by any automatic fee path after this phase.

## protocolFeeBps CONFIRM
**Not hardcoded.** Same pattern as `hookFeeBps`:
- Mutable factory default: `StonkzFeeHook.defaultProtocolFeeBps` (init `DEFAULT_PROTOCOL_FEE_BPS = 2500`).
- Cap: `PROTOCOL_FEE_BPS_MAX = 4000` (bps = 40% of hook fee).
- Owner: `setDefaultProtocolFeeBps(uint16)` enforces cap.
- Per-pool stamp at `registerPool` / `registerPoolCustom` via `_register(..., defaultProtocolFeeBps, ...)`.
- E2E proves mutability: set default to `3000` before settle → stamped `protocolFeeBps(token) == 3000`.

## Side-pool tests (MANDATORY — UNMODIFIED and GREEN)
SHA256 of test files **unchanged** from Phase 4 baseline (pre-edit):
- `SidePoolEconomics.t.sol` = `E2D995EDEB0489E4EBBBFD9346C54A09EEDB93667FC9F7AA5CC15E14E1F83C6A`
- `BuybackAccumulator.t.sol` = `204F276204A16F5484A97EED0896A1539FDC310787D9DBBAB84FCC98BFC167DB`

| Test | File | Status |
|---|---|---|
| `test_C2_provisional_mockBackend` | `SidePoolEconomics.t.sol` | **UNMODIFIED / GREEN** |
| `test_C2_rangeTopIs1000xBottom` | `SidePoolEconomics.t.sol` | **UNMODIFIED / GREEN** |
| `test_C3_preGenesisParkAndRelease` | `BuybackAccumulator.t.sol` | **UNMODIFIED / GREEN** |

Helper `check_C2_sidePoolDumpImmuneZeroStonkz` (not forge-prefixed) unchanged; exercised by `test_C2_provisional_mockBackend`.  
No side-pool test required edits. `FeeLocker.crankSideCompound` source path untouched in behavior.

## E2E (`test/FeechainE2E.t.sol`)
`test_e2e_settle_swap_flush_sideCompound`:
1. Mutable `protocolFeeBps` factory default → settle stamps it.
2. Main key: fee `0` pips + hook; side key: fee `3000` pips + no hook.
3. `crankMainFees` reverts `MainFeeCrankRetired`.
4. Swaps both directions → hook accrues pair currency.
5. `flush()` → treasury and feeReceiver hold stamped split; accumulator unchanged (carve only).
6. Side `accrueFees` → `crankSideCompound` → pending cleared; nothing collected out to treasury / receiver / accumulator.

## BuybackAccumulator reference classification
### Production (`contracts/src`)

| Location | Classification | Notes |
|---|---|---|
| `BuybackAccumulator.sol` (contract) | **retained-manual** | Deployed DCA instrument |
| `BuybackAccumulator.receiveCarve` | **retained-manual** | Settle-time 5% carve (not a fee path) |
| `BuybackAccumulator.receiveFees` | **retained-manual** | Manual top-up only; NatSpec updated |
| `BuybackAccumulator.parkSidePoolTokens` / `releaseSidePoolTokens` | **retained-manual** | Pre-genesis side parking |
| `BuybackAccumulator.crankBuyAndBurn` | **retained-manual** | Permissionless DCA crank |
| `BuybackAccumulator` events / `receive()` | **retained-manual** | Manual funding surfaces |
| `FeeLocker.accumulator` immutable + ctor | **retained-manual** | ABI/deploy wiring; unused by cranks |
| `FeeLocker.crankMainFees` → `receiveFees` call | **retired** | Reverts; no call site remains |
| `FeeLocker` NatSpec / `MainFeeCrankRetired` | **comment-only** / retired path | Documents retirement |
| `FeeLockerV2.crankMainFees` | **retired** | Already reverted (Phase 0); unchanged |
| `StonkzLiquidityStrategy.accumulator` + carve/park | **retained-manual** | Carve + side park only |
| `StonkzLiquidityStrategy` NatSpec (Phase 4 note) | **comment-only** | |
| `StonkzDirectListing.accumulator` + park | **retained-manual** | Side park only |

### Automatic fee path
**None remain.** Main fees: `StonkzFeeHook` accrue → `flush` → treasury / feeReceiver.  
No code path calls `receiveFees` automatically.

### Tests (harness — not production fee path)
All `new BuybackAccumulator(...)` / imports in `contracts/test/*` are **retained-manual** test wiring for settle/park/DCA coverage. E2E asserts accumulator is not auto-funded by flush.

### Docs (tracked) — stale wording flagged for Phase 5
| Doc | Classification |
|---|---|
| `docs/06-fee-architecture.md` L57–60 (Ladder → FeeLocker → BuybackAccumulator) | **comment-only** (historical gap description; Phase 5 reconciles) |
| `docs/fees-and-governance.md` (M3 main-pool → BuybackAccumulator) | **comment-only** / stale — Phase 5 |
| `docs/launch-plan.md` (fees → BuybackAccumulator utility) | **comment-only** / stale — Phase 5 |
| `docs/settlement.md` / `docs/mechanism-spec.md` carve + §8.3 | **retained-manual** (carve/DCA still correct) |
| Prior STOP reports mentioning Phase 4 retirement | **comment-only** |

## Suite
`forge test`: **137 passed, 0 failed** (39 suites).

## STOP
Phase 4 forensics pushed on `feat/m3-5-feechain`. Do not merge without David. Do not start Phase 5 until this report is pushed.
