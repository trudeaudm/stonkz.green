# STONKZ — Token Launchpad on Robinhood Chain

*Working plan, v0.1 — July 2026*

## 1. The one-liner

Stonkz is the place where anything gets a ticker. A permissionless token launchpad on Robinhood Chain that wraps every launch in the language of the stock market: tickers, IPOs, bookbuilds, opening bells, and up-only arrows. Gamified CCA auctions in, deep DEX liquidity out.

## 2. Why Robinhood Chain, why now

Robinhood Chain's public mainnet went live July 1, 2026. It is an Ethereum L2 built on the Arbitrum Platform, fully EVM-compatible, with ~100ms block times and native ERC-4337 account abstraction. Day-one ecosystem partners include Uniswap (deploying a dedicated AMM as the core public liquidity venue), Chainlink, Alchemy, BitGo, and LayerZero. Stock Tokens are live in 120+ countries (excluding the US) and the chain is natively connected to Robinhood's onchain wallet users — roughly 28M customers across 38 countries in the broader Robinhood ecosystem.

What this means for a launchpad:

- **The incumbent just vanished (July 2026).** Noxa, the chain's first and largest launchpad (60k tokens launched, ~$12M fees in one week, home of CASHCAT), abruptly halted launches July 11 and went dark two days later. RobinPad (one-tx deploy, direct Uniswap V3 liquidity, LP locks) remains; no audits are mentioned in coverage of either. The chain is in full memecoin season ($500M+ daily volume) with a trust vacuum at its center — "the audited launchpad that can't run away with your money" is the product this exact moment demands.

- **Fresh chain, no incumbent.** Every major chain's culture gets defined by its first breakout consumer app. Robinhood Chain has DeFi primitives at launch but no dominant launchpad yet. First-mover window is open but will close fast.
- **A retail-native audience.** Robinhood Wallet users are retail traders by definition. They already think in tickers, charts, and market hours. Stonkz meets them in a vocabulary they know, rather than asking them to learn crypto-native jargon.
- **Account abstraction out of the box.** ERC-4337 support means gas sponsorship, one-tap buys, and session keys — a launchpad UX that feels like placing a market order, not signing four wallet popups.
- **Graduation venue is already there.** Uniswap's dedicated AMM on-chain gives us a canonical destination for graduated tokens without building our own DEX.

## 3. Product concept

The brand plays it straight-faced: Stonkz treats meme launches with the full ceremony of a stock market listing. That contrast *is* the product personality.

**Core loop:**

1. **File your IPO (create).** Anyone launches a token in under a minute: name, cashtag ticker, logo, one-line "prospectus," and a choice of listing route: **IPO** (CCA auction) or **Direct Listing** (straight to DEX). Flat filing fee. No presale, no team allocation by default.
2. **The bookbuild (IPO route).** The token sells through a Continuous Clearing Auction: bidders set a budget and a max price, each block clears at a single uniform price, and early conviction gets cheaper average fills. This is mechanically how real IPOs price — we just make it feel like a game (see 4a).
3. **Ring the bell (settle).** Auction clears → the "opening print" is revealed → liquidity pools are seeded automatically at the discovered price → the bell rings on-site and every bidder gets a shareable opening-print card. Direct Listings skip straight to this step with creator-funded liquidity.
4. **The floor (discover).** The home feed is a trading floor: live tape, "IPOs closing soon" board, new filings, and a top-movers leaderboard styled like an index board.

**Two listing tiers (decided):**

- **Pink Sheets (meme tier).** Instant, anonymous, cheap. Standard fair-launch curve. This is the volume engine.
- **Blue Chip (project tier).** For serious launches: requires a real prospectus page, optional locked creator vesting (visible on-chain), linked socials, and a review checklist. Higher filing fee, "reporting company" badge, priority placement on The Floor. Blue Chip creators can post scheduled "earnings calls" (updates) to their token page.

The stock-market framing maps perfectly: memes are penny stocks, projects are listed companies.

**Other differentiators:**

- **Paper-trading mode.** A simulated portfolio for new users, on-brand for the Robinhood demographic and a low-risk onboarding funnel.
- **Stock-token pairs (later, pending legal).** Tokenized equities live natively on this chain; a future tier could pool against blue-chip Stock Tokens — a feature no other chain can copy.

## 4. Launch modes (decided: two)

**Mode 1 — IPO (the Stonkz Ladder Auction, custom mechanism — decided).** A deterministic ascending-price tranche auction with per-capita fills. Inspired by Uniswap's CCA (block-based, budget + max-price bids, sniper-proof) but with different allocation rules:

- **The ladder:** each block offers a tranche of tokens at a fixed price; the price steps up ONLY when the block's sales cover its ORIGINALLY SCHEDULED quantity, and the step size is DEMAND-SCALED: effective step = base step × (1 + live committed capital ÷ graduation threshold) — every 1/10 of graduation capital committed adds 10% of the base step, so hot books climb proportionally faster (recovers demand-responsive pricing without giving up the schedule). Priced-out/refunded capital stops counting. When blocks go unsold, the missed supply squishes into later blocks' offers — but the price-advance gate stays at the scheduled amount, so squished excess sells as bonus supply at the flat price rather than raising the clearing bar. (Simulator-discovered deadlock this prevents: if the gate tracked the squished offer, every stall would raise the bar while price stayed frozen — a one-way death spiral where no later bid could ever move the price again.)
- **Release curve (three phases):** (A) tranche size stays FLAT while ≤1 unique address is bidding — a lone early bidder can't hoover supply at the floor; (B) once 2+ addresses have competed (one-way ratchet, so leaving doesn't reset it), tranche size grows on a shallow curve, with cumulative release capped at 40% of auction supply pre-finale (hitting "the 40% wall" pauses sales and builds anticipation); (C) THE FINALE — the last 20% of auction time distributes ≥60% of auction supply on a sharp ramp (per-block tranche recomputed from remaining supply over remaining blocks, floored at the shallow rate so release never slows, guaranteeing full offering by the final block). Back-loading the finale makes the settlement price deep and manipulation-resistant — the same reasoning behind Uniswap CCA's requirement that final blocks sell significant supply, since the final price seeds the LP.
- **Per-capita fills with a size tilt:** within a block, the tranche splits among active addresses by weight = committed_capital^α, where α = log₂(1 + size_bonus) and size_bonus is a creator parameter (default 10%, 0 = pure per-capita). Every DOUBLING of committed capital adds the bonus to per-block fill — $200 fills 10% more than $100, but 150× the money only fills ~2× faster; radically sub-linear, so the whale-vs-fren story holds. Side effect: splitting capital across wallets is slightly less profitable than under pure per-capita (2 wallets = 2/1.1× ≈ 1.82× vs 2×). Water-filling redistribution is weight-proportional. All of one address's bids share one weighted share.
- **Bidders exit** when (a) their budget is exhausted, (b) the ladder price exceeds their max price, or (c) they hit the per-wallet supply cap. On exit, unconverted funds become claimable.
- **Per-wallet supply cap (creator parameter):** max % of total supply any single address can accumulate in the auction (e.g., 1%). On hitting the cap, the wallet stops filling and its remaining budget is claimable.
- **Creator parameters:** floor starting mcap ($2k–$100k), % of supply in auction, % of proceeds to LP, per-wallet cap %, ladder growth rate, duration.
- **Settlement & the LP reserve (the auction never sells everything):** the auction sells only a fraction of supply; the remainder is RESERVED to pair against raised funds in the pool — pools need both sides. At settlement, the pool is seeded with (LP% × raised) funds + (LP% × raised ÷ P_final) reserve tokens at the final price; same 15/85 dual-pool split; LP burned. **The reserve rulebook (auto-sized, fully deployed):** the auction/reserve split is DERIVED, not chosen: **auction : reserve = κ̂ : LP-share** (a = κ̂/(κ̂+LP), r = LP/(κ̂+LP)), where κ̂ = design print-to-average-sale-price ratio. Derivation: at a full raise, pairing need = LP% × raise ÷ P_final = LP% × auction-tokens ÷ κ; setting reserve = need gives the ratio. κ is pinned in a narrow band (~1.3) by the back-loaded schedule (60% of volume sells in the finale near the print) — measure it in the simulator, which logs realized κ every settlement. At κ̂=1.3: 100% LP share → 56.5:43.5; 80% → 61.9:38.1 (≈60:40). A full raise at κ=κ̂ consumes the reserve exactly; hotter paths (κ>κ̂) leave surplus (appreciation dividend → disposal choice); flatter paths (κ<κ̂) trigger the single-sided fallback, warned at settlement. Feasibility: selling the whole allocation at the floor raises only sell% × floor-mcap × launch-fraction, so graduation targets above that imply price appreciation and targets above the ladder's raise ceiling are auto-fails. **Oversubscription sells from the reserve:** once graduation is met, each block's tranche is topped up from the reserve (excess demand buys reserve tokens at the same block price), guarded so remaining reserve always covers pairing at the current price (conservative since P_final ≥ p); the price gate stays at the scheduled quantity, and post-graduation top-ups are GUARD-LIMITED ONLY (no pace throttle) — the full drainable reserve is on offer every block. Result: the reserve ends paired or sold whenever demand persists; pairing surplus survives only when buyers run out (the irreducible case: tokens cannot be sold to nobody), plus the appreciation dividend when the print far exceeds the average sale price. **Leftover tokens = auction excess (offered but unsold) + pairing surplus (solvency slack the guard preserved — small by construction). Leftover disposal is a creator parameter** (shown in recon, chosen at filing): thicker LP (extra pool depth), pro-rata airdrop to auction holders 🎁, creator wallet, or burn 🔥. Creator supply/capital parameters are HIERARCHICAL: total supply → creator holdback % (staking emissions etc.) + launch supply; launch supply → auction-sold % + LP reserve (the rest of the launch); plus LP share of raised capital (creator receives the rest). Sizing guarantee (from the ladder itself): every block sold at ≤ P_final, so tokens needed ≤ LP-share% × tokens sold; reserve covers any outcome iff sell% ≤ 100/(1 + LP-share%) of launch supply — independent of holdback; enforce in the constructor; if overridden and short, leftover funds seed single-sided range liquidity. Calibration note (simulator-derived): the graduation threshold must fit the auction's raise ceiling (~avg block price × auction supply) — a threshold above what a fully-sold auction can raise is an auto-fail.
- **Graduation threshold (adopted):** each auction sets a minimum raise; if unmet by auction end, the launch fails and 100% of committed funds are automatically claimable. Creator never touches funds from a failed raise.
- **End conditions:** supply exhausted (finale guarantees full offering) or time elapsed; graduation threshold decides success vs. full refund either way. (Formerly-open rules — unsold tranches and end condition — are now resolved by the flat-price rule and finale design.)

**Units principle:** the entire mechanism is denominated in % of supply and dollars — token count is cosmetic (1M vs 1B supply changes per-token price, nothing else; per-block dollar cost = schedule weight × market cap, supply cancels). Contracts, simulator, and analysis should all work in mcap/percentage terms; the floor-mcap slider ($2k–$100k) is the real economic input, and vanity supplies (420.69B) are free.

**Sybil analysis (must-read):** per-capita fills and per-wallet caps make wallet-splitting strictly profitable, so mitigations are required: NO sponsored gas on auction bids (sponsorship elsewhere is fine), a flat per-bid fee, and a minimum bid size — together these make an N-wallet split cost real money. Frame honestly in docs as friction, not prevention.

**Implementation note:** per-capita allocation permits O(1) per-share accumulator accounting (every active bidder = one share, masterchef-style), with exits bucketed at discrete ladder ticks. Fully custom `StonkzAuction` — DECIDED over building on Uniswap's CCA engine, to keep per-capita fills and full roadmap control (note: deployed contracts are immutable either way; the dependency risks were the not-production-ready release flag and CCA's capital-weighted allocation, not upgrades). Uniswap v4 pools are still the settlement venue — pool contracts themselves are Uniswap's audited code regardless.

**Guarded launch security ladder (replaces "audit when revenue allows"):** fees arrive after launch but exploit risk peaks at launch, so: (1) differential-test the contract against a reference model of the deterministic schedule + Foundry fuzz/invariant suite; (2) launch with hard caps — per-auction raise cap (~$50k), global TVL cap, and **`maxUniqueActives` (~300 pending clear-loop gas work; 0 = unlimited)** on new bidder addresses (existing addresses may always add bids) — raised/lifted stepwise alongside TVL caps; (3) pre-revenue review via audit contest (Code4rena/Sherlock, ~1–2 weeks, cost scales to scope); (4) day-one bug bounty, monitoring, pausability behind a timelock; (5) the ~$1M fee milestone funds the tier-1 audit that publicly removes the caps ("caps off, fully audited" as a marketing moment).

**Withdraw IPO (decided).** The creator can cancel an auction at any point before DEX settlement — the on-chain equivalent of an issuer pulling an IPO. All bidders are made fully whole, and the creator covers the refund gas. Mechanics:
- At filing, the creator posts a **refund bond** sized to the expected refund gas.
- On withdrawal, the auction enters a REFUNDING state: a keeper processes refunds in gas-safe batches, reimbursed from the bond (never an unbounded loop — that's a DoS vector). Bidders can also pull-claim instantly.
- Anti-manipulation: part of the bond is forfeited on withdrawal (cancelling isn't free), the ticker has a refiling cooldown, and creator profiles display a public withdrawn-IPO count.
- Week-1 verify: whether the CCA contracts support issuer cancellation natively; if not, `StonkzAuctionManager` wraps bid escrow and adds the withdrawal path.

**Mode 2 — Direct Listing.** Creator supplies initial liquidity and lists straight to the DEX. Fastest path, meme-friendly. Guardrails required: minimum liquidity floor, enforced LP burn or timelock, and a prominent "creator-priced" label since the opening price isn't market-discovered. This is the rug-vector mode — the UI must say so plainly.

**Both modes** settle into the same dual-pool structure: **15% of liquidity paired against STONKZ4663, 85% against ETH or USDG (creator's choice at filing)**, deployed atomically, LP burned. The 15% leg market-buys STONKZ4663 with half its budget — structural, recurring buy pressure on the protocol token. Implemented as a custom post-auction liquidity strategy on top of Uniswap's launcher rather than a from-scratch migrator. Risk note: the 15% leg correlates launched tokens to STONKZ4663 — great flywheel up, transmission risk down. Make the ratio governance-tunable (10–20%).

**Fees:** filing fee (higher for Blue Chip) + protocol fee on auction proceeds (e.g. 2%) or on direct-listing liquidity + ongoing swap-fee share where pool hooks allow.

## 4a. Making the CCA feel like a game

The bonding curve's magic was watching a line go up together in real time. A CCA can deliver the same dopamine with better fairness — the job is presentation:

- **The live book.** Clearing price per block rendered as the jagged stonkz arrow, ticking upward in real time. 100ms blocks make the tape feel alive even in a minutes-long auction.
- **Demand gauge.** The old "curve progress bar" becomes an oversubscription meter: "3.2× OVERSUBSCRIBED" filling up-and-to-the-right. Watching demand stack IS the game.
- **Bid status states.** Your bid is always in one of three states — IN THE MONEY / AT RISK / OUTBID — with push alerts and one-tap "raise bid." This is the moment-to-moment tension loop.
- **Early-bird edge, surfaced.** CCA natively gives early bidders cheaper average fills. Show it as a score: "your avg fill: $0.031 vs opening print $0.042 (+35%)." Badges: First 100 Bids, Diamond Bid (never lowered), Top Underwriter.
- **The opening print.** Auction end = countdown → clearing-price reveal → bell → shareable card ("I got in at $0.031, printed at $0.042"). The graduation ceremony survives, it just moved.
- **Season leaderboards.** Per-auction bidder boards + a season-long "underwriter league" — likely fuel for STONKZ4663 points/airdrop.

Design guardrail: gamify participation, not overbidding. Estimated cost and worst-case fill must always be visible before a bid confirms.

**Meme-tier note:** short-duration auctions (15–60 min) with low floors keep the Pink Sheets tier fast and degen-friendly; Blue Chip runs longer bookbuilds (hours–days) with identity-verified creator badges.

## 4b. STONKZ4663 — the protocol token

**Utility (v1):** the 15% pairing leg (constant graduation buy pressure), fee discounts on filing/trading when paid in STONKZ4663, staking share of protocol fees, and Blue Chip tier governance later.

**Supply/ticker:** the "4663" suffix is distinctive — lean into it in lore (e.g., total supply 4,663,000,000).

**Launch route (decided): the Genesis Auction.** STONKZ4663 launches as the first-ever CCA on Stonkz itself — "the first IPO on Stonkz is Stonkz." This also solves a hard sequencing dependency: the 15% pairing leg needs a live STONKZ4663 pool and price before any other token can list, so the protocol token must launch first regardless.

**Genesis mechanics:**
- Bookbuild runs in USDG (or ETH); longer duration than meme auctions (days, not minutes) to maximize participation and the story. Reference: Aztec sold ~15% of supply over five days.
- Special case: the genesis listing can't do the 15/85 split against its own token — it settles 100% into a single STONKZ4663/USDG pool at the discovered price. That pool becomes the reference every future launch's 15% leg buys into.
- Supply split to finalize (e.g., X% genesis auction / Y% early-user rewards / Z% treasury with locked on-chain vesting / LP reserve for pairing legs).
- Floor price, duration, and per-wallet parameters TBD.

Publish the full allocation on-chain with vesting contracts *before* the auction opens. A launchpad's protocol token gets held to a higher standard than anything launched on it. ⚠️ Legal note: selling your own protocol token via auction is the most securities-like act in this plan — review with token-experienced counsel before public announcement.

## 5. Architecture

**Contracts (Solidity, EVM):**
- `StonkzFactory` — token creation, ticker uniqueness, tier registry, filing fees.
- `StonkzAuction` — the custom Ladder Auction: deterministic tranche/price schedule, per-capita fills via per-share accumulator accounting, per-wallet caps, exit bucketing, claimable refunds. Now our highest-risk contract alongside the liquidity strategy.
- Uniswap Liquidity Launchpad periphery — referenced for pool seeding at settlement; the CCA auction engine itself is no longer used.
- `StonkzAuctionManager` — wraps the auction with issuer withdrawal: refund bond, REFUNDING state, keeper-driven batch refunds + instant pull-claims, cooldowns, forfeiture.
- `StonkzLiquidityStrategy` — custom post-auction strategy: market-buys STONKZ4663, deploys the 15/85 dual pools atomically, burns LP. This is our highest-risk custom contract.
- `StonkzDirectListing` — direct-listing wrapper: liquidity floor checks, LP burn/lock enforcement, same dual-pool split.
- `Stonkz4663` — protocol token + staking/fee-share contract.
- Token: minimal ERC-20 with transfer restrictions off (freely tradable), metadata pointer on-chain.

**Infra:**
- Alchemy RPC + webhooks for indexing; fallback self-hosted node.
- Indexer service (Ponder or custom) feeding a Postgres store; websocket layer for the live tape.
- ERC-4337 bundler + paymaster: sponsor gas for first N trades per new wallet ("commission-free," on brand).
- Chainlink feeds for USD-denominated market caps and the graduation threshold.
- TRM or similar for compliance screening on frontend access.

**Clients:** Mobile-first web app (the mockups reflect this), then PWA. Telegram bot for degens as a fast follow.

**Security:** two independent audits on the curve + migrator before mainnet, bug bounty at launch, timelocked admin, no upgradeable curve contracts.

## 6. Regulatory posture (flag early)

Robinhood Chain is permissionless, so deployment is open — but a launchpad brand-adjacent to a licensed US broker will draw attention. Items for counsel:

- Memecoin launchpads currently sit outside most securities frameworks, but "IPO/prospectus" theming and anything touching Stock Token pairs needs careful review — parody framing helps, pairing meme tokens with tokenized equities may not.
- Geofencing policy (US access?), marketing claims, and fee structures reviewed per jurisdiction. Stock Tokens themselves exclude the US.
- Trademark: "Stonkz" is a meme term (likely defensible) but clear it, and keep visual identity distinct from Robinhood's brand to avoid implied endorsement.

This is not legal advice — bring in counsel experienced with token launch platforms before testnet marketing, not after.

## 7. Go-to-market

- **Phase 0 (weeks 1–4):** Contracts on testnet, private alpha with 20–50 creators. Join Robinhood's 2026 Arbitrum Open House buildathon circuit ($1M program) for visibility and potential grants.
- **Phase 1 (weeks 5–8):** Mainnet launch with a flagship community token event ("the first IPO"), creator referral fees live from day one.
- **Phase 2 (months 3–6):** Earnings-call badges, paper-trading mode, Telegram bot, explore Stock-Token pairing pending legal.

**KPIs:** tokens launched/day, curve volume, graduation rate, D7 trader retention, fee revenue, % of trades via sponsored gas (funnel health).

## 8. Build plan — solo founder with Claude + Cursor

You're building this yourself with AI pair-programming. Realistic and increasingly common, but sequence matters:

**Stack:** Foundry (contracts + tests), Solidity 0.8.x, Next.js + wagmi/viem (frontend), Ponder (indexer), Alchemy RPC on Robinhood Chain, Uniswap v3/v4 periphery for migration.

**Build order:**
1. **Week 1–2 — Ladder math on paper first.** Build a reference model (Python/notebook) of the full mechanism: tranche schedule, per-capita fills with water-filling, wallet caps, exits at price ticks, graduation threshold, refunds. Run the A/B/C example plus edge cases (cap hit mid-block, mass exit at a tick, thin demand, sybil splits). This model later becomes the differential-testing oracle. Read Uniswap's CCA whitepaper as prior art only.
2. **Week 2–6 — Contracts.** `StonkzAuction` (per-share accumulator accounting) → `StonkzLiquidityStrategy` → `StonkzDirectListing` → `StonkzAuctionManager` (withdraw + refund bond). Foundry fuzz + invariant tests, differential-tested against the reference model: "auction can never be drained," "sum of fills ≤ tranche," "refunds always claimable," "settlement succeeds or fully reverts."
3. **Week 6–8 — Robinhood Chain testnet deploy** + Ponder indexer + minimal auction UI. Run real test auctions with real people; try to break the ladder.
4. **Week 8–9 — Audit contest** (Code4rena/Sherlock) while polishing the full frontend, alerts, 4337 paymaster (never on bids), tiers, flex cards.
5. **Week 9 — Mainnet dress rehearsal (burner deploy).** Deploy the full stack to Robinhood Chain mainnet from a throwaway deployer and test everything against real conditions (real gas, real Uniswap v4, real indexer latency). Nothing announced, nothing official — no allowlists or stealth measures; the rehearsal runs the exact production code path. Anyone who finds and apes an unannounced test contract does so at their own risk; the guarded-launch caps (already in the contracts) keep any stranger exposure tiny. The deploy must be a scripted one-command Foundry run with all config in code, so the rehearsal also tests the deploy script itself.
6. **Week 9+ — Fresh production deploy + guarded mainnet.** Redeploy everything clean from the same script: new addresses, zero test history, admin/pauser/fee roles assigned at construction to hardened keys (hardware wallet minimum; 2-of-3 multisig + timelock preferred) — deployer key ends the day with no powers. STONKZ4663 genesis runs ONLY on these contracts. Launch with raise/TVL caps + day-one bug bounty; scale caps with confidence; tier-1 audit at the ~$1M fee milestone removes them publicly.

**Solo-founder budget:** audit $30–80k, infra $200–500/mo pre-scale, legal consult $5–15k, small incentive pool. Roughly $50–100k to a credible mainnet launch — the audit dominates.

## 9. Decisions log

- ✅ Tiers: both memes (Pink Sheets) and projects (Blue Chip)
- ✅ Auction engine: FULLY CUSTOM `StonkzAuction` (Ladder Auction) — Uniswap CCA rejected; v4 pools remain the settlement venue
- ✅ Deployment: burner-address mainnet dress rehearsal (unannounced, exact production code, caps keep exposure tiny, apers ape at own risk) → fresh scripted production redeploy with hardened admin keys; genesis only on final contracts
- ✅ Security path: guarded launch (raise/TVL caps + `maxUniqueActives`) + audit contest pre-revenue → tier-1 audit at ~$1M fees
- ✅ Graduation threshold: minimum raise or 100% auto-refund
- ✅ Launch modes: IPO (custom Stonkz Ladder Auction — per-capita fills, per-wallet caps) + Direct Listing
- ✅ Anti-sybil baseline: no sponsored gas on bids, flat per-bid fee, minimum bid size
- ✅ Release curve: flat until competition (one-way ratchet) → shallow (40% pre-finale cap) → finale: last 20% of time distributes ≥60% of supply
- ✅ Price rule: advances when a block's ORIGINALLY SCHEDULED quantity sells; squished rollover is bonus supply at flat price
- ✅ LP reserve: auction sells ≤ ~55% of supply (constructor-enforced vs LP share); reserve pairs the pool at P_final; excess reserve burned
- ⬜ Ladder parameters to finalize: default price growth rate, shallow-curve rate, finale ramp ratio
- ✅ Withdraw IPO: creator can cancel pre-settlement; full refunds, gas paid via creator's refund bond
- ✅ Graduation liquidity: 15% vs STONKZ4663, 85% vs ETH or USDG (creator picks)
- ✅ Brand: STONKZ (stonks was taken). Domains: stonkz.meme (primary — a launchpad at .meme sells itself) + stonkz.green (redirect, "the line is green"); protocol token $STONKZ4663
- ✅ Build: solo, with Claude + Cursor, on Uniswap's CCA contracts
- ✅ STONKZ4663 launch: Genesis Auction — the first CCA on Stonkz itself (see 4b)
- ⬜ Genesis parameters: supply split, floor price, duration
- ⬜ Auction defaults per tier (duration, floors), fee percentages
- ⬜ Verify CCA contract deployment on Robinhood Chain
- ⬜ US geofencing policy
