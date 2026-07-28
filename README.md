# STONKZ 📈 — stonkz.meme

The trenches deserve a launchpad that can't run away with the money.
Token launchpad on Robinhood Chain: custom **Stonkz Ladder Auction**
(per-capita fills with a size tilt, demand-gated price, three-phase release,
graduation-or-refund), settling into Uniswap v4 with κ̂-derived LP pairing.

## Layout
```
docs/
  mechanism-spec.md      ← THE spec (start here)
  launch-plan.md         ← business plan, decisions log, security ladder
reference/
  engine.js              ← executable reference (differential-testing oracle)
  engine.test.js         ← 19 locked behaviors:  node reference/engine.test.js
  ladder-simulator.html  ← interactive mechanism lab (open in a browser)
  memeworld-mockup.html  ← full frontend mockup w/ simulated engine
contracts/               ← Foundry: auction/settlement/direct/CTO IMPLEMENTED;
                           StonkzAuctionManager remains a skeleton (TODO body)
web/                     ← frontend (to be ported from the mockup)
```

## Quickstart
```bash
node reference/engine.test.js          # the oracle must be green
cd contracts && forge install foundry-rs/forge-std && forge build
forge test                             # gas_limit pinned in foundry.toml
```

## Dev requirements
- **Node 20** (CI uses `actions/setup-node` with `node-version: "20"`)
- **Foundry** — CI pins `foundry-rs/foundry-toolchain` to **v1.7.1**. Local
  installs may skew (e.g. 1.6.0-rc1); known — prefer CI as the source of truth
  when versions disagree.

## Build order (from the plan)
1. Port the reference model → Foundry test vectors (gen-vectors.js) 
2. StonkzAuction (O(1) accumulator accounting) + differential + invariant suite
3. LiquidityStrategy (two-position settlement) → DirectListing → Manager (bonds)
4. Testnet → audit contest → burner mainnet rehearsal → fresh production deploy
