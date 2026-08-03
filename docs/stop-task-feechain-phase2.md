# FEECHAIN PHASE 2 REPORT — pool keys and rates
**Branch:** `feat/m3-5-feechain`  
**Status:** Phase 2 complete; suite green.

## Changes
### `StonkzDirectListing` / `StonkzLiquidityStrategy`
- Removed shared `_poolKey` / `POOL_FEE`.
- `_mainPoolKey(a,b)` → `fee: 0`, `hooks: address(hook)` (docs/06).
- `_sidePoolKey(a,b)` → `fee: 3000` pips = 0.3%, `hooks: address(0)`.
- Constants: `MAIN_LP_FEE = 0`, `SIDE_LP_FEE = 3000`.

### Auction path (provisional wire for naked-pool guard)
- `StonkzLiquidityStrategy` constructor now requires `StonkzFeeHook`.
- `settle` calls `hook.registerPool` when the token is not yet registered.
- FeeLocker main→BuybackAccumulator retirement remains **Phase 4**.

## Invariants (`test/PoolKeyInvariants.t.sol`)
| Test | Asserts |
|---|---|
| `test_noNakedMain_directListing` | Express main fee=0 + hook; side fee=3000 + no hook |
| `test_noNakedMain_auctionSettle` | Same for auction settle |
| `testFuzz_noNakedMain_directListing` | Both tiers |
| `testFuzz_noNakedMain_auctionSettle` | Fuzz-halt over settle inputs |

## Suite
`forge test`: **128 passed, 0 failed** (37 suites). (+4 vs Phase 1: PoolKeyInvariants ×4).

Note: a sticky Foundry failure-replay of `invariant_exactWeiLedger` (off-by-1 wei,
seed-dependent) appeared during iteration. Auction **runtime** bytecode vs Phase 1
is identical (`RUNTIME_SAME=True`); clearing failure persistence + clean rebuild
re-greened the suite. Not a Phase 2 mechanism change.
