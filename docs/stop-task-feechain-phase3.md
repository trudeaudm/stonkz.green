# FEECHAIN PHASE 3 REPORT — hook redesign, accrue-and-flush, custom deploys
**Branch:** `feat/m3-5-feechain`  
**Status:** Phase 3 complete; suite green.

## Units discipline
| Symbol | Unit | Value | Percent |
|---|---|---|---|
| `MAIN_LP_FEE` (PoolKey.fee) | pips | 0 | 0% |
| `SIDE_LP_FEE` (PoolKey.fee) | pips | 3000 | 0.3% |
| `defaultHookFeeBps` / stamped `hookFeeBps` | bps | 100 | 1% |
| `HOOK_FEE_BPS_MAX` | bps | 1000 | 10% |
| `defaultProtocolFeeBps` / stamped `protocolFeeBps` | bps | 2500 | 25% of hook fee |
| `PROTOCOL_FEE_BPS_MAX` | bps | 4000 | 40% of hook fee |

PoolKey.fee (pips) and hookFeeBps (bps) never mix. Every fee constant carries a trailing
`// <unit> = <percent>` comment.

## Hook redesign (`StonkzFeeHook`)
- Pair-currency-side take: mock quotes `feeAmount = notional × hookFeeBps / 10_000` and
  calls `afterSwap(key, pair, feeAmount)`. No conversion / crank.
- Per-pool stamp at `registerPool` from `defaultHookFeeBps` / `defaultProtocolFeeBps`.
- Retire `RECEIVER_BPS` / `TREASURY_BPS` → split by stamped `protocolFeeBps`.
- Accrue-and-flush (docs/06 ### Distribution): swap path only accrues; `flush(token)`
  pushes independently per recipient.
- Owner-only `registerPoolCustom(..., hookFeeBps_)` + `CustomFeeDeploy` event.
- Trade-never-reverts: `afterSwap` wraps accrue in try/catch; force-fail fuzz proves it.

## Tests (`test/FeePhase3.t.sol`)
- `test_units_default100bps_swapYieldsExact1Percent` — stamped 100 bps AND exact 1% fee
- Custom deploy: 300 bps stamp / concurrent standard 100 bps / OOB 1001 reverts
- Hostile receiver: cannot revert swap; cannot block treasury flush
- Fuzz: accrued == sum of per-swap fees; hook-fail trade never reverts

## Suite
`forge test`: **136 passed, 0 failed** (38 suites).
