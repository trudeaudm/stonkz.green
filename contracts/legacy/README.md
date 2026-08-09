# Legacy — waterfill `StonkzAuction` (RETIRED)

**Status:** NOT a deploy target. Never include in rehearsal or official deploy manifests.

| Live path | Contract |
|---|---|
| Express | `StonkzDirectListing` |
| Ladder | `StonkzLadderAuction` |

This directory holds the M1 waterfill auction (`StonkzAuction` + `IStonkzAuction` +
skeleton `StonkzAuctionManager`) and its forensic/differential tests, moved out of
`contracts/src` and `contracts/test` so they are outside the live Foundry tree and
off CI.

## Known escrow bug (preserved — do not lose)

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

## Not compiled by default

Live `contracts/foundry.toml` uses `src = "src"` and `test` under `contracts/test`.
Nothing here is imported by live Express/Ladder/vault/FEECHAIN code. Do not add
this path to CI.
