# STONKZ DECISIONS LEDGER
*(project-knowledge doc 3/5 · chronological rulings + repo milestone map · D = David ruled, C = Claude default pending overrule)*

## Repo milestone map (git truth, reconciled 2026-07-28 status report)
| Milestone | Merge | Scope |
|---|---|---|
| M1 | 1b34952 (07-23) | spec + reference oracle + StonkzAuction + differential suite |
| M2/2.5 | d7ec5bc PR#1 | lazy accounting (Q′/S3/F1′/G1‴/H1), Task T packing, E1 valve, I5 clamp |
| M3 | 21eaf1b PR#2 | settlement: strategy, BuybackAccumulator, FeeLocker, terminal states, §8 |
| M3-review | b04b61d PR#3 | D2/D3 promoted to deployment ladder; M3.5 scope; C3 partially provisional |
| M4 | 4328c1d PR#4 | hook fees, direct listing, checkpointed token, CTOGovernor |
| M4-amend | 94ad73c PR#5 | explicit CTO candidate; per-address cooldown; 24h token spacing |
| PRE-M5 | 5621196 PR#6 | working-docs gitignore, forge v1.7.1 pin, scan divergences:0, SCALE-TRACK rename |
All CI green. Suite counts: oracle 19; fuzz 200; invariants 11; M3 suites 19; M4 suites 31 (C3=15).

**Infra stack ruling: Render + Namecheap + Google Workspace — Cloudflare superseded, do not reintroduce.**

## Mechanism & economics rulings
- **[D] Per-capita fills; demand-gated ladder; 3-phase curve; committed-bid escrow** — founding design (first session).
- **[D] Reject Uniswap CCA engine** — full roadmap control + novel per-capita mechanic worth custom contract.
- **[D] Immutable per-launch contracts** — accepted incl. consequences; platform evolves by launch VERSIONS.
- **[D] lpShare default 100%** (80/20 was test-only); creator raise share = opt-down at filing.
- **[D] Carve 5% flat, NO raise threshold/tiers** (was 10% → David cut to 5 for approachability + token LP health; uniformity: cliffs get gamed).
- **[D] No atomic buys in settle** (Claude: sandwich surface) → BuybackAccumulator drip+burn; David's single-sided side-pool design [startPrice+1tick, 1000×] adopted — dump-immune, upside-accreting.
- **[D] Reserves are operating-capital tools, not compensation** — renamed creatorReserve/treasuryReserve; [C→D accepted] declaredUse optional immutable strings.
- **[D] Holdback delivery chosen AT FILING** (INSTANT 10-min / VEST params), published in recon (David moved it from graduation-time to filing-time after Claude noted bidders should price it).
- **[D] "Go hook"** — per-swap fee conversion v1 (Bankr/Doppler parity; Claude initially favored cranks, reversed after David's Bankr observation + gas/sandwich reassessment). Best-effort discipline; crank fallback.
- **[D] Fee split 75/25 → then MUTABLE**: factory protocolFeeBps ∈ [0,4000] hardcoded bounds, per-token immutable stamp, effective immediately — **[D] explicitly rejected 24h increase timelock** ("silly and overprotective").
- **[D] Protocol share is discretionary; only a PORTION funds buyback/burn** — site copy corrected to match.
- **[D] CTO system**: 1% initiate / 0.1% vote / 80% of at-large / supply-weighted / re-clamp anti-revote (David's design; Claude: min(snapshot,now) checkpoints). [C→D] candidate explicit+immutable; pass→candidate. [C] cooldown per-address not per-token (squatter fix) — accepted via merge.
- **[D] Direct-to-DEX**: 95% burnt full-range + 5% side pool; $4k/$8k tiers; volatility difference emergent.

## Ladder v1.5 session (2026-07-26, simulator-verified, IN M5 DRAFT — not yet in repo)
- **[D] Count-based dynamic step** replaces capital-scaled (Claude showed detonation; David proposed count basis, rate down when bidders drop). [C→D] ADDRESSES not bids.
- **[D] Duration normalization** — David caught N-compounding bug; rates now per-auction, N-th root per block. [C] Duration invariance as named invariant.
- **[D] Scarcity accelerator concept** ("sell from reserve, price moves faster") — [C] keyed to allocation depletion (drain-keyed deadlocks), self-financing via lp·R/P. β default 2.
- **[D] Tier durations** 1h/4h/24h/7d (David's 5-tier list; [C→D] dropped 12h+48h, added none). **[D] Names accepted**: GOD CANDLE, THE 4H, THE DAILY, THE ROADSHOW ([C] names; David: "these are great").
- **[D] Heat presets 300/250/200/150** (David retuned from Claude's 400/300/200/100 after lab feel-testing; earlier David cranked base to 250 finding defaults flat — Claude quantified cost, κ̂ recalibrated).
- **[C] κ̂ presets 1.41/1.38/1.34/1.29** — measured; ROADSHOW extrapolation confirmed by 150-run (1.29 measured).
- **[D] LP health bands** 40–50/45–55/50–60/55–65 = TOTAL pool (cash+token) vs mcap (David's definition confirmed with $5k/$20k/$25k example). [C] two-component gate (+cash floor band/3); [C] band-first disposal; [C] two-bound filing validator. Genesis collision (49.77% vs 50%): **[C default] holdback→39%**; alternatives DAILY floor 48% / lp 96.5% — DAVID HAS NOT RULED.
- **[D] Breathing ladder**: decay thought-experiment David-initiated; **[D] reactivation of unclaimed priced-out bids REQUIRED if decay ships** ("the whole point — pick up capital left behind"); [C→D] v2 roadmap, not genesis ("not sure it is necessary, though... interesting and exciting").
- **[C] Genesis defaults pending David**: disposal = holder airdrop; carve = park for first self-buyback. **[D] Genesis layout**: $40k floor, 0.02%-era → DAILY preset, target $15k+ raise, 5% treasury, 60% launch (10 protocol/30 emissions — pre-collision numbers), threshold [C] $6k.

## Brand, site, process rulings
- **[D] Positioning = technology leadership** (fair-launch ladder auction, clean experience); anti-rug framing RETIRED as identity (kept as engineering-standards evidence).
- **[D] Brand = memeworld** (sky gradient, floating scenery, Impact logo, win95 chrome, ticker tape, stamps, misspelling gags) — reference file: stonks-memeworld-full-dummy.html. Claude's dark "Robinhood terminal" reskin rejected.
- **[D] Protocol token unnamed publicly** until launch.
- **[D] X handle @stonkzgreen**; Verified Orgs application after site+email live.
- **[C] "Roadshow" + IPO framing on legal-review list** (securities vocabulary).
- **[D] Process**: Claude = design authority + prompt author; Cursor = implementer; STOP protocol with push-before-ruling; status-report reconcile at milestone boundaries ([C] proposed, [D] adopted).
- **Harness-labeling lessons** (2×): "raised > committed" and fuzz float-divergence were both TEST-HARNESS defects, not mechanism bugs — David's number-smell caught both. Verify labels before mechanism panic.

## Session 2026-07-27 (website launch + mechanism copy)
- **[D] M5 = LADDER v1.5.** The segment+heap gas work in gas-attribution.md / lazy-clearing-design.md also called itself "M5"; that work is renamed **SCALE-TRACK** (no number — gated on measured gas, not sequence). Housekeeping renames it in both docs.
- **[D] Hosting stack: Render (site) + Namecheap (DNS) + Google Workspace (email).** Supersedes every Cloudflare plan. Site repo `trudeaudm/stonkz-site`, separate from contracts — rationale: audit scope must stay free of non-audited artifacts.
- **[D] External audit is NOT a launch gate.** Public audit contest and tier-1 firm review remain roadmap; bug bounty ships with mainnet. Site copy had claimed "mainnet does not open before this ladder is climbed" — never a David ruling, removed 2026-07-27 (commit d8a6ee2).
- **[D] Motion runs by default on EVERY surface (site AND app), for everyone**, incl. visitors whose OS requests reduced motion. Mitigation: persistent user toggle (taskbar + localStorage + `?motion=off`). Deliberate departure from the_floor.txt rule 4.
- **[D] Express: 100% of launch supply becomes liquidity and NONE of it can leave** — 95% burnt one-sided in the token's own pool, 5% seeds the protocol side pool; **both locked forever**, neither withdrawable by creator or protocol. Side-pool fees compound into the position. Earlier copy said "95% of supply is the liquidity," which understated it.
- **[C→D] "fair share" replaces "equal share"** on marketing surfaces. Mechanism/CRT layer keeps exact language because fills are NOT equal — see doc 2 §0.
- **[D] The name is STONKZ**; the S-spelling is legacy, not a variant. (Carried from the brand-system session; recorded here as promised.)

### Harness/claim-verification lesson — THIRD occurrence of this class
Claude published a **false number on the live site**: claimed 1000× capital moves fill "by single-digit percent." Actual is 2.59×. Cause: read doc 2's "α=log₂(1+bonus) tilts mildly" as a bounding coefficient when β is an exponent. David caught it by asking "is it really only 10% for 1000x capital?" and settled it with a two-line sim run.
Prior two in this class: "raised > committed" and the fuzz float-divergence — both harness-labeling defects, both caught by David's number-smell.
**Standing rule: any numeric claim destined for a public surface is simulator-verified before it ships. Never derive a public figure from prose in the docs.**

## Session 2026-07-28 (site audit + symbol hygiene)
- **[D] Site copy corrected.** The 2026-07-27 false figure was recorded as fixed but was STILL LIVE on stonkz.green at audit time: "scaling your bid by 1,000× moves your share by single-digit percent", plus "bounded by the creator's filed bonus parameter". The published `<details>` formula was also wrong — `(1 + α·log₂(1+bonus_i))` with capital absent from the exponent. Both replaced with the doc 2 §0 form. **Lesson: a ledger entry saying a fix shipped is not evidence it shipped — verify against the live surface.**
- **[D] Audit-gating language removed, 3 instances**: "mainnet does not open before this ladder is climbed" (built_different.txt — the exact string logged as removed in d8a6ee2, regressed or never fully applied), "mainnet comes after the audit ladder... not before" (readme.txt), "survives contact with an auditor" (status.txt).
- **[D] LP HELTH cash floor** published as `band_width / 3`; correct is `bandLo / 3` (16.7% at THE DAILY, not 3.3%).
- **[C] Symbol split: σ for the scarcity accelerator, β for the size bonus only.** Docs 2/4 renamed. Rationale: the single glyph is the mechanical cause of the exponent-as-bound misread. Solidity/reference naming follows at M5 (`scarcityCoef` vs `sizeBonusBps`).
- **[C] Doc 5 self-contradiction fixed**: its register and product-copy exemplars still modelled "same fill"/"equal share" directly above the ruling banning them — the reinfection vector for any copy written from the guide.

---

---
## [D] 2026-08-03 STONKZ TOKENOMICS

Protocol token identity
- [D] Token is the protocol token for stonkz.green. Ticker: STONKZ.
- [D] Supersedes the STONK4663 working name throughout. The `stonkz4663` constructor
      immutable in contracts/src/StonkzLiquidityStrategy.sol and its mirror in
      StonkzDirectListing.sol are now misnamed. Rename is QUEUED, not done here.

Supply and allocation
- [D] Total supply 100,000,000. Fixed. No mint function.
- [D] Allocation, PROVISIONAL pending simulator modelling:
      60% auction (60,000,000) / 30% emissions (30,000,000) /
      5% community (5,000,000) / 5% team, vested (5,000,000).
- [D] "Market cap" means FULLY DILUTED VALUE everywhere, in docs, site copy and UI.
      Therefore price = FDV / 100,000,000 exactly.
- [D] Genesis clears at ~$100k FDV => $0.001 per token. $1.00 per token = $100M FDV.
- [D] Supply number is a deliberately plain round number. Meme-numerology supplies
      (420,690,000; 2,147,483,647; 4,294,967,296) were considered and REJECTED.
      Rationale: total supply is a mechanic, and the voice rule is dead literal about
      mechanics. The joke belongs in the chrome, not the capital structure. Also
      4,294,967,296 is already Optimism's supply.

Fee structure — THREE DISTINCT LAYERS. Do not conflate them.
- [D] Layer 1, swap fee: 1% on every pool, all pool types.
- [D] Layer 2, protocol's share of that swap fee:
        launched token main pool (vs ETH/USDG) ....... 25% of fee = 25 bps of volume
        launched token side pool (vs STONKZ) ......... 0%  — compounds into the LP
        STONKZ pool (has no side pool) ............... 100% of fee = 100 bps of volume
      Consequence: a dollar of STONKZ volume is worth 4.21x a dollar of launched-token volume.
- [D] Layer 3, disbursement of the protocol's share:
        30% to stakers, paid in ETH/USDG, never in STONKZ
        30% to buyback-and-burn
        40% to team, operations, no token claim
- [D] Protocol revenue is always denominated in ETH/USDG. The token side of each fee is
      swapped to native on collection. NOTE: no such swap path exists in code at 3bd6c39.

Emissions and staking
- [D] Emissions pool is 30,000,000 tokens. Benchmark case is 15% APR against 30% of total
      supply staked, giving 4,500,000/yr and a 6.67 year runway. 30% is a BENCHMARK, not
      a forecast — actual participation will fluctuate.
- [D] Token emissions are a BOOTSTRAPPING mechanism with a hard end date. The durable
      product is the ETH/USDG fee share, which is perpetual. Public copy must not present
      15% APR as a standing yield.
- [D] Because the Layer 3 staker split (30%) equals the benchmark staked fraction (30%),
      they cancel. At benchmark:
        staker ETH yield  = 1 / revenue_multiple
        annual burn       = 30 / revenue_multiple, as % of supply
        blended yield     = 15% + (1 / revenue_multiple), while emissions run
      General form off-benchmark: ETH yield = (0.30 / staked_fraction) / revenue_multiple.
      Burn is unaffected by participation.
- [D] 6.67x revenue multiple is the equilibrium point: buyback purchases exactly
      4,500,000/yr, matching emissions, so supply is flat and ETH yield equals 15%.

Buyback
- [D] The 30% buyback bucket is ALWAYS buy-and-burn. Permanent, no exceptions.
- [D] REJECTED: diverting buyback to top up the staking vault, whether by discretion or by
      a runway-floor rule. Rationale: burn is the only value accrual a non-staker receives,
      and removing it pushes participation up, which dilutes fee share and drains the vault
      faster. Buying STONKZ to pay stakers is also a round trip with slippage — economically
      near-identical to simply raising the Layer 3 staker split, but in a more volatile form.
- [D] REJECTED: pairing buyback proceeds into protocol-owned liquidity. Noted as viable,
      not chosen.

Factory switches — onchain, owner-controlled
- [D] The factory gains four switches, to enable the genesis launch and to allow later
      correction of parameters that prove wrong:
        1. lock a token's liquidity at deploy (bool)
        2. create the protocol-token side pool at deploy (bool)
        3. side pool share of total liquidity (bps)
        4. deployments on/off, with an allowlist of owner-approved deployers
- [D] Switch 2 exists specifically because the STONKZ genesis cannot pair against itself.
      It is set false for that one deployment.
- [D] Follow the established pattern: mutable at the factory, STAMPED IMMUTABLY per token
      at launch. A holder must verify their token's terms from the token, not from current
      factory state.
---

---
## [D] 2026-08-03 M3.5 FEE ARCHITECTURE
- [D] Revenue is taken at the hook, in pair currency, on both launch paths.
- [D] Main pool LP fee = 0. Hook fee = 1%. Applies to every main pool including STONKZ.
- [D] Side pools keep LP fee 30 bps, no hook, fees compound into the locked position.
- [D] Fee is taken from the pair-currency side of each swap (input on buys, output on
      sells). SUPERSEDES the M4 A1 convert-after-take design, its best-effort conversion,
      and its crank fallback. No internal swap is performed.
- [D] Hook fee is per-pool, stamped immutably at launch from a mutable, bounded factory
      default. Same pattern as protocolFeeBps.
- [D] `_poolKey` splits into `_mainPoolKey` and `_sidePoolKey`.
- [D] The auction path (StonkzLiquidityStrategy) must wire the hook. The FeeLocker main-fee
      route to BuybackAccumulator is retired. Side-pool compounding unaffected.
- [D] Rationale for LP fee 0 over LP fee 1%: identical gross revenue, but hook fees are
      outside the PoolManager fee path and cannot be taxed by Uniswap governance, whereas a
      1% LP tier draws the full 10bp cap once v4 fees activate on Robinhood Chain.
- [D] Layer 3 (30% stakers / 30% buyback-and-burn / 40% team) is a TARGET, NOT A COMMITMENT.
      Routing from treasury is manual and discretionary. Public copy must not state it as a
      guarantee. Corrects the 2026-08-03 tokenomics entry, which implied automation.
- [D] The 40% cap is a promise about LAUNCHED tokens. It does not bind the STONKZ pool,
      where the protocol is the creator and both fee legs return to the same entity.
- [NOTE] At 3bd6c39 no 1% exists anywhere in code. The hook has no rate of its own — it
      receives a caller-supplied feeAmount and only splits it. Protocol take at HEAD is
      0.3% × 20% = 6 bps against the 25 bps assumed throughout the 2026-08-03 tokenomics
      session. Every revenue figure in that session is CONDITIONAL on this spec shipping.
---

---
## [D] 2026-08-03 DOCS PRIVACY BOUNDARY
- [D] The docs/ privacy rule is restated: NUMBERED working docs (docs/0[1-9]-*.md,
      docs/00-START-HERE.md) are private and gitignored. The legacy M3/M4 spec docs
      (fees-and-governance.md, mechanism-spec.md, settlement.md, launch-plan.md,
      stop-task-m4.md) are TRACKED AND PUBLIC — they predate the numbering convention
      and their git history is already permanent on the public repo.
- [D] Ruling: the four legacy specs stay tracked, with public-safe supersession banners
      committed (2026-08-03). Untracking was rejected: history survives untracking, and
      visible "superseded" markers serve diligence readers better than files vanishing
      from HEAD.
- [D] Banner discipline for public files: no references to gitignored docs, no current
      figures. "Superseded; authoritative spec is internal pending publication" is the
      ceiling.
- [NOTE] Consequence: the public history permanently contains the STONK4663 name, the
      4,663,000,000 supply, CCA genesis framing, and the retired fee designs. All stale
      before exposure — the public record shows abandoned plans, not current ones.
- [NOTE] Any future doc must be born on the correct side of this boundary: numbered and
      ignored if private, or written public-safe if tracked. No third category.
---

---
## [D] 2026-08-03 FEECHAIN GATE 1
- [D] Hook fee factory-default bounds [0, 1000] bps, DEFAULT 100 bps (1%). The
      original prompt's "default 1000" was a units error, caught at this gate.
- [D] docs/06 requirement #1 reworded to pair-currency capture. The M4
      convert-token-half phrasing was residual, not a requirement.
- [D] Side pool LP fee 30 bps confirmed. CORRECTION to "[D] 2026-08-03 STONKZ
      TOKENOMICS": "Layer 1, swap fee: 1% on every pool" applies to MAIN pools via
      the hook. Side pools: 30 bps LP fee, no hook, no revenue, full compounding.
- [D] Distribution is accrue-and-flush per docs/06 "### Distribution". No transfers
      in the swap path. flush() is permissionless. A broken recipient can never
      block swaps or the other recipient's funds.
- [D] ADDENDUM: owner-only custom-fee deploy variant accepts explicit hookFeeBps
      per launch (bounds [0, 1000]); emits CustomFeeDeploy (or equivalent). Standard
      path still stamps the factory default. Concurrent standard deploys unaffected.
      See docs/06 "### Custom deploys".

---
---
## [D] 2026-08-03 STAKING AND VESTING
- [D] Emissions: owner-set APR-targeting. Target 1500 bps intended; HARD CAP 50000 bps
      (500%). Not guaranteed; owner adjusts freely under the cap. EmissionRateChanged
      receipt on every change. Supersedes the fixed-APR-vs-fixed-budget question in
      docs/04 (resolved: neither — owner-targeted with cap).
- [D] Emissions land CLAIMABLE. Compounding is a deliberate user action.
- [D] Staker fee share accrues PER-ASSET (ETH, USDG). No normalisation swap. Claims are
      per-asset plus claimAll; one asset's failed send never blocks the other.
- [D] Team 5,000,000: 60-day delay, then 5,000/day linear (~2.9 yr total).
- [D] Community 5,000,000: vault, any amount, 24h request->execute timelock, cancelable.
- [D] Factory and deploy switch are NOT renounceable. Stated purpose: factory migration —
      when a new factory ships, the old one's deploys switch OFF so all new launches use
      the latest. The switch is the upgrade path, not an emergency brake.
- [D] RH Chain protocolFeeController() check: DROPPED. LP-fee-0 architecture zeroes
      Uniswap exposure by construction; verification adds nothing David wants to claim.
- [D] Vampire mitigation: CLOSED, no action. Structural friction only, revisit only on
      observed vamping.
- [NOTE] Genesis parameters are being worked in a separate chat; not tracked here.
---

## [D] 2026-08-03 VANITY PREFIX 0x4663
- [D] Every token contract deployed through the STONKZ factory has an address BEGINNING
      0x4663. Enforced ON-CHAIN: the factory computes the CREATE2 address and reverts if
      the top two bytes != 0x4663. The vanity is a factory rule, not a convention.
- [D] Salts are mined OFF-CHAIN (frontend or deploy service; 16 bits, ~65,536 attempts,
      milliseconds) and BOUND TO THE DEPLOYER on-chain: effective salt =
      keccak256(msg.sender, userSalt), so a mempool-observed salt is worthless to a
      front-runner.
- [D] Leading chosen over trailing: explorers and wallets truncate as 0x4663...xxxx, so
      the prefix is always visible.
- [D] LORE NOTE: 4663 lives on as the address signature, not the ticker. The STONK4663
      NAME remains superseded (see [D] 2026-08-03 STONKZ TOKENOMICS). Future sessions
      must not "clean up" the vanity as leftover naming cruft.
- [C] CANDIDATE, unruled: the STONKZ genesis deployment itself mines a deeper prefix,
      0x46634663 (32 bits, ~4.3B attempts, GPU-scale, one-time). The protocol token
      visibly out-mines its children. Decide at genesis prep.
---
## [D] 2026-08-04 MAINNET PATH
- [D] Community 5,000,000 purpose: stimulating and rewarding the community. Specific
      programs are ops decisions drawn under the vault's 24h cancelable timelock.
- [D] NO TESTNET. Path: full anonymous REHEARSAL deploy of the entire stack to Robinhood
      Chain mainnet -> integration-test against a Render preview URL (never stonkz.green
      / stonkz.meme) -> clean OFFICIAL redeploy. Rationale: near-zero gas, allowlist
      gates launches regardless of discovery, factory migration is the ruled recovery
      path, per-token stamping contains bad deploys.
- [D] Rehearsal anonymity (best-effort, not cryptographic; retroactive discoverability
      accepted): source unverified; fresh deployer keys funded via an unlinked route;
      no 0x4663 vanity; generic contract/token names. Vanity, official names, and
      verification are official-deploy ceremony.
- [D] CLASSIFIED-DIFF GATE between rehearsal and official (replaces bytecode identity,
      which contract renames alone would break):
      Class A (free): contract names, NatSpec, comments, error strings, event names
        (signatures unchanged), metadata. No runtime semantics.
      Class B (re-rehearse): EVERYTHING else — constants, logic, visibility, storage
        layout, signatures. NO size exemption: "small" is a judgment, and the 1000-vs-
        100 bps units error was a one-character Class B change.
      Enforcement: official deploys from a tagged commit; git diff rehearsal-tag..
      official-tag reviewed hunk-by-hunk, each classified; any Class B hunk means the
      official candidate becomes the next rehearsal. Full suite green on the official
      commit regardless. Re-rehearsal is cheap by design (scripted, near-free gas) —
      the rule costs a button press, not a phase.
- [D] Rehearsal scope: factory + all switches drilled on-chain, Express path, fee hook
      with real keeper flush cadence, side pools vs a THROWAWAY protocol-token stand-in,
      real small-value lifecycle (deploy -> launch -> swaps both ways -> flush ->
      side-pool compound). Ladder joins rehearsal once M5 exists; rehearsal infra is
      built once and reused.
- [D] Rehearsal contracts are DISPOSABLE: deploy switch off after testing, never
      migrated, never referenced by official infra.
- [NOTE] Side-pool address dependency: rehearsal uses the stand-in; the real STONKZ
      address (genesis chat) is needed only for official.

## [D] 2026-08-04 SETTLEMENT CARVE
- [D] The protocol carve on auction raises is ADJUSTABLE on contract: carveBps, mutable
      factory default, hard bounds [0, 1000] (0-10% of raise). LAUNCH VALUE: 400 (4%).
- [D] Stamped IMMUTABLY per auction at filing: the carve a creator sees at filing is the
      carve that settlement applies, regardless of later factory changes. Third
      application of the stamp pattern (protocolFeeBps, hookFeeBps, carveBps).
- [D] SUPERSEDES the fixed 5% carve in the 2026-08-03 entries and docs/06. All prior
      revenue modelling used 5%; settlement-revenue figures scale by 0.8 at the launch
      value.
- [NOTE] Express has no raise and no carve — unchanged.
- [NOTE] UNITS: carveBps is BASIS POINTS of the ETH/USDG raise (400 = 4%). Applies at
      settlement, before the raise-ratio split to LP.

## [D] 2026-08-08 M5 INTAKE
- [D] MODULAR REPLACEABILITY: the contracts that keep the protocol functional (launchpad
      and its services) are kept modular so any one can be replaced without redeploying
      the others. Mechanism: owner-settable cross-contract references with change events;
      migration = redeploy-and-repoint. Explicitly NO proxies and no extra indirection
      contracts — simplicity over upgradeability machinery. EXCEPTIONS: token contracts
      (ruled), and pools + their hooks (v4 physics: the hook address is part of the
      PoolKey; a new hook applies to new pools only). CAVEAT: the creator vault is
      replaceable for FUTURE launches only — existing locks never migrate.
- [D] AUCTION BIDS ARE NOT SWAPS. Bids pay the 4% carve only; the 1% hook fee applies to
      post-graduation pool trading only. Preserves lpHealth >= floor by construction and
      closes handoff blocker #3 (fees never touch the auction path).
- [D] Handoff blocker "carve base": RESOLVED by [D] 2026-08-04 SETTLEMENT CARVE — 4% of
      RAISE, carveBps stamped per auction, bounds [0,1000]. "5% of LP funds" is stale.
- [D] RUNG PACING IS TIME-DERIVED: one rung per duration/1000 seconds (sim N=1000 is
      design resolution, not chain blocks; one-rung-per-chain-block at 100ms would give
      GOD CANDLE ~36,000 rungs). Contract constant per tier: rungPeriod = duration/1000.
- [D] CREATOR MANAGEMENT VAULT (full spec = docs/10). One vault, locks indefinitely,
      DIRECTED EXITS:
      * Direct release to wallet: PROPORTIONAL SERIAL QUEUE — 3 hours per 1% of the
        token's total supply requested. Requests queue FIFO; a countdown starts only
        when the previous request completes. Example (ruled): 1% + 2% + 1% queued
        together -> 1% at 3h, 2% at 9h, 1% at 12h. Total exit time is invariant to
        splitting (N% always takes 3N hours end-to-end); max re-entry rate is 8% of
        total supply per day; the queue is public before anything lands.
      * Protocol utility destinations, faster by trust level: staking emissions
        instant; airdropper ~12h; dividends / auto single-sided LP / vesting delays
        set in docs/10.
      * Every move is request -> delay -> execute, CANCELABLE during the window;
        canceling a queued item reflows later countdowns earlier.
      SUPERSEDES the 10-day minimum linear vest from the sim-chat handoff (David:
        ignore it). The circulating-mcap exclusion at the graduation gate is earned by
        the proportional queue: locked supply cannot re-enter faster than 8%/day and
        every exit is announced by the queue itself.
- [D] Gate fallback stands: until the vault is live and the lock verifiable on-chain,
      the graduation gate uses FDV (no circulating exclusion).
- [NOTE] Doc numbering: ladder spec = docs/09-ladder-spec.md; creator vault = docs/10.
      The sim chat's "docs/06-vault-design.md" is a rejected strawman — never create it
      in this repo under that number.

## [D] 2026-08-09 M5 COMPLETE
- [D] The Ladder Auction is merged to main (merge 0a21dc2, --no-ff, CI green). Built per
      docs/09 as amended: rung rule + Mmax, time-derived integer periods, O(1) idle
      catch-up, per-address weights (split == single EXACT), typed gates, three-leg
      settlement exact, stamped carveBps, 5% side pool vs owner-settable STONKZ ref,
      vault-only holdback with circFrac exclusion and availability guard, MIN_ASK_BPS.
- [D] Mid-chain rulings folded into docs/09 by this close-out: vault-only holdback /
      TAKE removed (2026-08-09), circFrac in ceiling AND gate, integer periodIndex.
- [D] Evidence: 10/10 vectors A1-A5 (09 regenerated for vault semantics, TAKE vector
      deleted); 256-run adversarial fuzz incl. holdback sweep — no strategy graduates
      lpHealth < tierFloor; escrow/monotonicity/refund-once invariants; ~92% line
      coverage on auction+settlement; canary-verified non-vacuous harness.
- [NOTE] Not claimed: external review (bounty at mainnet; Ladder + hook top the scope);
      docs/10 vault (holdback unavailable until it ships and is wired); real-chain
      behavior (mainnet rehearsal is the exam).
## [D] 2026-08-09 VAULT + SETTLE COMPLETE
- [D] StonkzVault merged (642399a; hardening e887fd1): per-token custody, proportional
      serial queue (108 s/bps // 3h per 1%), cancel-reflow, rate-stamp, lockedBalance
      (conservative: pending requests excluded), empty path registry. setVaultRef
      requires code; holdback settlement REVERTS on codeless vaultRef — no bare-
      transfer fallback, ever.
- [D] Permissionless settle confirmed + factory path fixed (87294f3): settlement
      address STAMPED in Params at construction (4th stamp application); owner may
      rewire ONLY pre-bell — SettlementFrozenAfterBell after. Random-address crank
      e2e green through factory -> vault.
- [D] LEGACY RETIRED (3058176): StonkzAuction/-Manager/IStonkzAuction ->
      contracts/legacy/ with tests; dropped from CI; known escrow bug recorded in
      legacy README (seed 0xc7e3...78a9, claim->runAway interleave). NEVER in any
      deploy manifest. Deploy targets: Express = StonkzDirectListing, Ladder =
      StonkzLadderAuction.
## [D] 2026-08-10 ONE DEPLOY + SWITCHES COMPLETE
- [D] ONE OFFICIAL DEPLOY, supersedes the anonymous-rehearsal path (2026-08-04 entries):
      real names, 0x4663 vanity, verified source, deployed to Robinhood Chain (id 4663 —
      the chain id IS the vanity number) behind the DeployControls allowlist
      (deployer-only at birth). Site wired to a Render preview URL until go-live. The
      allowlist is the rehearsal environment; a local fork proof precedes any mainnet
      step; recovery from a real bug is the ruled factory-migration path.
- [D] STONKZ TOKEN CONTRACT DEPLOYS AT LAUNCH, GENESIS DEFERRED: 100,000,000 minted and
      parked, zero circulating, no pools. Side pools pair against the real address from
      the first launch and sit DORMANT (single-sided, no STONKZ circulating = untradeable
      by construction) until genesis activates them. Genesis is a separate event;
      David's expected clearing band: $50k-150k FDV ($0.0005-0.0015/token); floor lean
      DAILY $10k — genesis chat rules it.
- [D] SWITCHES MERGED (594a17f): DeployControls (off=blocked / on+empty=open /
      on+nonempty=gated; closed at birth; NOT renounceable — stated purpose = factory
      migration); Express factory (CREATE2, deployer-bound salts, vanity-ready);
      createSidePool + sidePoolBps stamps (bounds [0,2000], default 500 // 5%; genesis
      case proven); liquidityLocked stamp (default TRUE, read-once at construction,
      unlockRecipient = creator stamped immutable, 2048-run locked-never-withdraws fuzz).
- [D] SIDE-POOL REFPRICE (ruling B): stonkzRefPriceWad is PAIR-WEI PER STONKZ, per-pair
      factory defaults stamped per deploy — ETH 2.5e11 (~$0.001 at $4k ETH; re-check at
      deploy, runbook item), USDG 1e15; RefPriceUnset revert on unconfigured pairs;
      mid-band err-high rationale; closed a latent 1000x side-pool drain (both paths
      assumed STONKZ=$1). QUEUED post-genesis: pool-derived TWAP reference.
- [D] RIDER B AMENDED (standing process): byte-identical gates apply to vectors/*.json
      (ground truth); harness .t.sol may change ONLY as ABI-literal hunks under per-hunk
      behavior-preservation review.
- [D] STAKING: fast-follow, high priority, targeted to exist by genesis. Not a
      platform-launch gate.
- [D] BUG BOUNTY is a launch gate: SECURITY.md + security@stonkz.green + published tiers
      before addresses circulate; scope = hook, Ladder, settlement, vault, factories.
- [D] SYBIL WORDING: public claim is "protection against sybil," no numeric claims.
- [NOTE] Ladder file ~29.3M gas: fits Orbit's 32M limit, pennies at 0.06 gwei; if filing
      grows, split file+initialize. Deploy chain's fork proof must land a real file.
---
## [D] 2026-08-10 V4-CANON (real-v4-is-a-launch-gate)
- [D] real-v4-is-a-launch-gate: production binds to Robinhood deployed PoolManager
      0x8366a39CC670B4001A1121B8F6A443A643e40951 via V4Adapter unlock/settle; hooks via
      PoolKey.hooks (CREATE2 mine 0x4663 top + 0x088 flags). feat/v4-canon; launch-deploy
      frozen until merge.
- [D] FEECHAIN honesty (ledger correction, verbatim): "FEECHAIN proved the 100 bps
      exact-in fee formula against a real in-test PoolManager BeforeSwapDelta harness;
      it did not ship production unlock/BeforeSwapDelta integration or bind to
      Robinhood's deployed PoolManager."
- [D] protocolFeeController REOPENED as monitored (supersedes 2026-08-03 DROPPED):
      live on RH at 0x6d0009504D129CF5002Dba61D9Ae8575AA79314c (V4FeeAdapter), owned by
      same key as PM (0x2BAD…); main pools LP-fee-0 → 0 protocol fee (immune by
      architecture); side-pool exposure ≤5 bp each direction if/when policy applies to
      LP-fee-3000 pools (fork probe 2026-08-10).
- [D] Ladder §7 geometry construction (not the price ranges) fixed for real PM:
      orientation-aware cash/ask tick placement; liq=1 dust retired → LiquidityDust revert.
- [NOTE] Fork gate file() gas 29,274,312 vs mock 29.3M vs Orbit 32M — see
      docs/stop-task-v4canon-phase4.md / docs/18-v4canon-report.md (local).

## [D] 2026-08-10 GENESIS VIA PLATFORM (supersedes "deploy STONKZ at launch")
- [D] SUPERSEDES the 2026-08-10 ONE DEPLOY clause "STONKZ token contract deploys at
      launch, parked." That was wrong. STONKZ launches THROUGH THE PLATFORM at genesis
      like any other token: a Ladder auction filed on StonkzLadderFactory that mints the
      100M as part of the flow. No pre-deploy of the token. It proves the tech by using
      the tech.
- [D] stonkzRef at deploy = a STAND-IN dead-token address (real deployed ERC-20 on 4663,
      inert). Pre-genesis side pools pair against it, dormant and harmless (no STONKZ
      circulates). At genesis, BEFORE STONKZ's own auction, owner repoints stonkzRef to
      the real STONKZ address (modularity ruling, one tx). Launches stamped against the
      stand-in keep their stamped ref â€” dormant, never interfere.
- [D] STONKZ genesis auction files with createSidePool=FALSE (a token cannot pair against
      itself; the ruled/merged switch exists for exactly this).
- [D] Deployer EOA funded FROM the Safe: accepted. Fully doxxed project, Safe is public
      governance; the on-chain link reveals nothing hidden.
- [NOTE] Genesis remaining work is PARAMETERS + one ruling (how the 40M non-auction
      supply — emissions/community/team — is seeded), NOT unbuilt contract machinery.
      Genesis chat owns it. Does not block today's deploy.

## [D] 2026-08-11 PREDEPLOY-REFIT close-out notes
- [D] R-L3CAP: NO special protocolFeeBps for STONKZ Layer-2. Default 25% of hook fee
      (`DEFAULT_PROTOCOL_FEE_BPS = 2500`) through genesis. Genesis feeReceiver = treasury
      (`TREASURY_ADDRESS` / FeeHook protocolTreasury). No code change.
- [D] Naming: `stonkzRef` → `sideTokenRef`; `refPriceWad(sideToken, pairCurrency)`.
- [D] Park/strategy RETIRED; loud `SideTokenRefUnset` on Express list + Ladder file/settle
      when `createSidePool=true` and ref unset. FeeLocker V1 → `contracts/legacy/`.
- [NOTE] `feat/launch-deploy` held at `3fcdf74` until this branch merges; then re-point.

## [D] 2026-08-11 CARVE TREASURY FACTORY-STAMP
- **[D] Protocol carve destination is factory-stamped** (`StonkzLadderFactory.carveTreasury`),
  not filer-supplied. `file()` overwrites `p.treasury` — closes carve-capture once the
  allowlist opens. Creator cash-holdback + FeeHook `feeReceiver` remain creator/filer slots.
- **[D] Two-Safe split is structural:** `TREASURY_ADDRESS` → FeeHook fee Safe (flush);
  `CARVE_TREASURY_ADDRESS` → protocol Safe (raise carve). Carve may be Safe/EOA (zero-guard only).
- Express has no raise carve — no Express change.

