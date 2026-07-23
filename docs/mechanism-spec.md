# StonkzAuction — Mechanism Specification v1.0

> The source of truth for the Solidity implementation. Every rule here was designed
> interactively and validated in `reference/ladder-simulator.html`; the executable
> version of this spec is `reference/engine.js` (regression suite: `engine.test.js`,
> 19 checks). **Solidity behavior must match the reference engine** — differential
> tests are mandatory, not optional.

## 0. Units principle

The entire mechanism is denominated in **% of supply and dollars (USDG)**. Token
count is cosmetic: 1M vs 420.69B supply changes per-token price and nothing else
(per-block dollar cost = schedule weight × market cap; supply cancels). Contracts
store schedule weights as fractions and validate parameters in mcap terms.

Supply hierarchy (all mechanism fractions are of **launch supply**):

```
total supply
├── creator holdback %          (staking emissions etc. — never sold, never paired)
└── launch supply
    ├── auction allocation      (sold on the ladder)     = κ̂ / (κ̂ + LP-share)
    └── LP reserve              (pairs the pool)         = LP-share / (κ̂ + LP-share)
```

## 1. Creator parameters (constructor args)

| Param | Range / default | Notes |
|---|---|---|
| floor starting mcap | $2k–$100k | floor price = mcap / total supply |
| graduation threshold | $ raised | must be ≤ the ladder's raise ceiling (see §7) |
| auction duration | blocks | ~100ms blocks on Robinhood Chain |
| base price step | basis points | scales with demand (§4); clamp ≥ 0 |
| wallet cap | % of total supply | max any address accumulates |
| size bonus | % per 2× capital, default 10, 0 = pure per-capita | §3 |
| LP share of raise | %, default 80 | creator receives the rest |
| creator holdback | % of total supply, default 0 | |
| κ̂ (design print/avg ratio) | default 1.3 | calibrate via simulator batches |
| leftover disposal | thicker-LP / holders-airdrop / creator / burn | shown in recon |

**Derived (never inputs):** auction:reserve split = κ̂ : LP-share.

## 2. Bids

- **Committed**: no retraction. Funds unlock only when a position is priced out
  (outbid at its max — immediately claimable) or at auction end.
- A bid = (budget, max price). Multiple bids per address allowed; **all of an
  address's bids share ONE weighted fill share** (no self-sybil). The address's
  per-block fill distributes across its in-range positions by equal water-fill.
- Anti-sybil friction: min bid 10 USDG, flat per-bid fee, **never sponsor gas on bids**.

## 3. Fills — per-capita with a size tilt

Within a block, the tranche splits among **active addresses** by weight:

```
weight = committed_capital ^ α,   α = log2(1 + size_bonus)
```

Every doubling of committed capital adds `size_bonus` to per-block fill
($200 fills +10% vs $100 at the default; 150× the money ≈ 2× the fill).
Water-filling: if an address's take is constrained (budget / wallet cap), the
remainder redistributes weight-proportionally among unconstrained actives.
Exits: budget exhausted (`all in`), priced out at max (`claimable now`), wallet
cap reached (`capped`, leftover locked till end).

## 4. The ladder — price rule

- Price starts at floor, and **advances only when a block's sales cover its
  ORIGINALLY SCHEDULED quantity** (the gate). Squished/top-up extra is bonus
  supply at the flat price — never a higher bar (prevents the stall death-spiral).
- **Demand-scaled step**: `effective_step = base_step × (1 + committed_live / graduation_threshold)`.
  Every 1/10 of graduation capital committed adds 10% of the base step.
  Priced-out (refunded) capital stops counting.

## 5. Release curve — three phases, one shape

Weights over N blocks, precomputed; per-block **offer = remaining × w[b] / Σw[b..N]**
(the squish: reproduces the schedule exactly under full demand; rolls unsold
supply forward shape-preservingly otherwise).

- **A — flat** while ≤ 1 unique address has bid (offer capped at the block-1 rate).
  Competition ratchet is one-way (committed bids can't leave anyway).
- **B — shallow**: linear ramp over the first 80% of blocks, summing to 40% of
  the auction allocation.
- **C — finale**: last 20% of blocks distribute 60%, entering at exactly the
  shallow curve's exit rate (seamless handoff, ratio 1.000) then geometric,
  ratio solved numerically; monotone at all N.

## 6. Oversubscription — selling from the reserve

Once `raised ≥ graduation`, each block's offer is topped up **from the reserve**:

```
drainable = max(0, reserveRemaining − need_now − future_headroom) / (1 + LP-share)
need_now        = LP-share × raised / current_price          (conservative: p ≤ P_final)
future_headroom = LP-share × remaining_scheduled / κ̂
topup           = drainable × w[b] / Σw[b..N]                 (weight-paced: no one-block cliff)
```

Invariant (verified per-block): **top-ups fire only with positive guard slack** —
reserve sales can never cause pairing insolvency. Result: the reserve ends
**paired or sold** whenever demand persists.

## 7. Graduation & feasibility

- `raised ≥ threshold` at end → **graduates**; else the auction fails and 100%
  of committed funds are auto-claimable (creator never touches them).
- Raise ceiling: a fully-sold allocation at the floor raises only
  `sell% × floor_mcap × launch_fraction`; thresholds above the ladder's ceiling
  (given step params) are auto-fails — **validate in the constructor**.
- Creator may ring the bell early only if graduated (warn: irreversible).
  Withdraw ("run away") cancels pre-settlement: keeper-batch refunds funded by
  the creator's bond; partial bond forfeit + 7-day refile cooldown + public count.

## 8. Settlement

Let `P` = last price that actually sold, `F = LP-share × raised`.

- Sold tokens → bidders (claim at their per-position accounting).
- **Price-setting position**: `F` dollars + `F / P` tokens spanning the print —
  the ratio IS the opening price. (Depositing everything full-range instead
  opens the pool at `F / all_tokens`, catastrophically below the print.)
- **Leftover = pairing surplus + auction excess** → creator's disposal choice:
  - thicker LP → single-sided range depth ABOVE the print (does not move open)
  - holders → pro-rata airdrop by auction holdings
  - creator wallet (visible in recon up front)
  - burn 🔥
- Realized κ = P / avg-sale-price is emitted; κ > κ̂ → surplus (appreciation
  dividend); κ < κ̂ → shortfall, covered by single-sided fallback (warned).
- Dual-pool: 15% of LP funds vs $STONKZ4663 (market-bought), 85% vs ETH/USDG
  (creator's pick). LP burned. Deployed contracts immutable.

## 9. Invariants (Foundry suite — differential-test all against reference/engine.js)

1. **Conservation**: sold + paired + surplus + auctionExcess == launch supply (to the token).
2. **Solvency**: top-ups only with positive guard slack; reserve sales never cause insolvency.
3. **Gate**: price advances iff scheduled quantity sold; never advances on partial/topup-only sales.
4. **Per-capita**: equal committed capital ⇒ equal fills; weight ratio == (c2/c1)^α exactly.
5. **One share per address**: N positions from one address fill identically to 1 position of equal total weight basis.
6. **Wallet cap**: address total never exceeds cap; capped leftover claimable at end.
7. **Committed bids**: no path reduces a position's budget except fills; priced-out ⇒ full unspent claimable.
8. **Refund-all on failure**: below threshold ⇒ every position's full budget claimable; auction can never be drained.
9. **Settlement atomicity**: settles fully or reverts fully.
10. **Weights**: Σ = 1, monotone, 40/60 phase split, seamless handoff — for all N.

## 10. Security posture (see docs/launch-plan.md for full ladder)

Guarded launch: per-auction raise cap (~$50k) + global TVL cap → Foundry
fuzz/invariant + differential suite → Code4rena/Sherlock contest pre-revenue →
day-one bounty → burner-address mainnet dress rehearsal (unannounced, exact
production code, scripted one-command deploy) → **fresh production redeploy**,
admin roles to hardened keys at construction, deployer ends powerless. Genesis
($STONKZ4663) runs only on final contracts. Tier-1 audit at ~$1M fees removes
caps publicly.
