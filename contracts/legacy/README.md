# Legacy — retired contracts (NOT deploy targets)

**Status:** NOT a deploy target. Never include in rehearsal or official deploy manifests.

| Live path | Contract |
|---|---|
| Express | `StonkzDirectListing` + `FeeLockerV2` |
| Ladder | `StonkzLadderAuction` + `LadderSettlement` |

## FeeLocker (V1) — PREDEPLOY-REFIT Phase 3

`FeeLocker.sol` here is the pre-V2 locker (main crank retired; side compound). Production
Express/LadderSettlement use **`FeeLockerV2`**. Retained for historical strategy / FEECHAIN
tests that still import it — **do not delete**.

## Waterfill `StonkzAuction` (RETIRED)

This directory also holds the M1 waterfill auction (`StonkzAuction` + `IStonkzAuction` +
skeleton `StonkzAuctionManager`) and its forensic/differential tests, moved out of
`contracts/src` and `contracts/test` so they are outside the live Foundry tree and
off CI.

### Known escrow bug (preserved — do not lose)

Pinned from CI run 31319715297 (attempt 1), seed:

```
0xc7e344fca608811254e399a94cb2bc6e210c12bb6046e28ac776e407333478a9
```

Reproduce (from `contracts/` with a profile that includes this tree, if ever needed):

```
forge test --match-test invariant_exactWeiLedger \
  --fuzz-seed 0xc7e344fca608811254e399a94cb2bc6e210c12bb6046e28ac776e407333478a9 -vvv
```

**Mechanism:** OutPrice `claim` refunds only `budget - spent` and leaves `spent` in
`totalEscrowed`. Later `runAway` sets `done=true`, `graduated=false`. `escrowBook()`
then treats the book as failure-shaped and **drops** that `spent` for usd-claimed
positions → `totalEscrowed != escrowBook`. Real bug; not fixed (legacy retired).

## Not compiled by default (waterfill tree)

Live `contracts/foundry.toml` uses `src = "src"` and `test` under `contracts/test`.
`FeeLocker.sol` / `StonkzLiquidityStrategy.sol` may still compile as dependencies of
live tests that import them — that is intentional historical coverage, not a deploy path.
