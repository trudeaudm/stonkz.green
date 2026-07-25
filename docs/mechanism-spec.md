# StonkzAuction — Mechanism Specification v1.1

> The source of truth for the Solidity implementation. Every rule here was designed
> interactively and validated in `reference/ladder-simulator.html`; the executable
> version of this spec is `reference/engine.js` (regression suite: `engine.test.js`,
> 19 checks). **Solidity behavior must match the reference engine** — differential
> tests are mandatory, not optional.
>
> v1.1 (Milestone 3): settlement rewrite (§8), reserve renames (§0–§1), default
> `lpShareBps = 10000`. Auction-engine math (§2–§7, §9 I2–I10) is unchanged.

## 0. Units principle

The entire mechanism is denominated in **% of supply and dollars (USDG)**. Token
count is cosmetic: 1M vs 420.69B supply changes per-token price and nothing else
(per-block dollar cost = schedule weight × market cap; supply cancels). Contracts
store schedule weights as fractions and validate parameters in mcap terms.

Supply hierarchy (all mechanism fractions are of **launch supply**):

```
total supply
├── creatorReserve %     (token-side holdback — operating capital: emissions,
│                         rewards, protocol-owned LP; never sold, never paired)
└── launch supply
    ├── auction allocation   (sold on the ladder)  = κ̂ / (κ̂ + LP-share)
    └── LP reserve           (pairs the pools)     = LP-share / (κ̂ + LP-share)
```

Raise-side holdback (of raised funds, when LP-share < 100%): **treasuryReserve** —
operating capital for treasury / post-graduation dip defense. Opt-down filing
parameter; default is zero (100% of raise → LP).

Reserves are tools, not fees. Creator compensation is expected post-launch from
what they build — never framed as a "cut" or "compensation" in contracts, events,
or UI copy.

## 1. Creator parameters (constructor / filing args)

| Param | Range / default | Notes |
|---|---|---|
| floor starting mcap | $2k–$100k | floor price = mcap / total supply |
| graduation threshold | $ raised | must be ≤ the ladder's raise ceiling (see §7) |
| auction duration | blocks | ~100ms blocks on Robinhood Chain |
| base price step | basis points | scales with demand (§4); clamp ≥ 0 |
| wallet cap | % of total supply | max any address accumulates |
| size bonus | % per 2× capital, default 10, 0 = pure per-capita | §3 |
| LP share of raise | %, **default 100** (`lpShareBps = 10000`) | opt-down: remainder is `treasuryReserve` |
| creatorReserve | % of total supply, default 0 | token-side holdback; see §8.4 |
| κ̂ (design print/avg ratio) | default 1.3 | calibrate via simulator batches |
| leftover disposal | thicker-LP / holders-airdrop / creator / burn | shown in recon |
| declaredUse (per reserve) | optional short string, may be empty | immutable; transparency only — §8.5 |
| creatorReserve delivery | `INSTANT` \| `VEST(duration, linear rate)` | chosen at filing, immutable — §8.4 |

**Derived (never inputs):** auction:reserve split = κ̂ : LP-share.
At the canonical default (κ̂ = 1.3, LP-share = 100%): **auction:LP = 56.5 : 43.5**.

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

Let `P` = last price that actually sold (the print). Let
`F = LP-share × raised` (LP-designated pair-currency funds).

### 8.0 Terminal state machine

Exactly one terminal flag, mutually exclusive:

| State | Entered when | Claim paths |
|---|---|---|
| **Settled** | `settle()` succeeds after graduation | post-settle token + unspent USD claims |
| **Failed** | auction ends below threshold | full-budget refunds (I8) |
| **RanAway** | creator `runAway()` pre-settlement | bonded keeper/pull refunds |

No settle / refund / runAway claim path may interleave across states; every claim
is keyed to the single flag. Settles fully or reverts fully (I9).

### 8.1 Funds split at settle (no market buys)

```
F_main  = 95% × F     → main pool (pair currency ↔ userToken) at the print
F_carve =  5% × F     → BuybackAccumulator (pair currency; see §8.3)
```

The 5% carve is **flat for ALL launches** — no raise threshold, no tiers.
Rationale on record: a tiered carve (e.g. "5% only above $X") creates a cliff
that launchers game by splitting filings or sizing just under the threshold; a
uniform carve removes the game. **No market purchases inside `settle()`** —
atomic STONKZ4663 conversion is sandwichable / griefable; the accumulator is
cranked asynchronously (§8.3).

`treasuryReserve = (1 − LP-share) × raised` (zero at the default) delivers to the
creator/treasury wallet at settle.

### 8.2 Main pool — price-setting + surplus

Sold tokens → bidders (claim at their per-position accounting).

- **Price-setting position**: `F_main` dollars + `F_main / P` tokens spanning the
  print — the ratio IS the opening price.
  **INVARIANT**: `pricePosition.tokens × P == pricePosition.usd` (wei-derived
  bound). A naive full-range deposit of all remaining tokens MUST be unreachable
  (explicit test): that would open the pool at `F / all_tokens`, catastrophically
  below the print.
- **Surplus** = pairing surplus + auction excess → creator's disposal choice
  (immutable at filing, shown in recon):
  - thicker LP → single-sided range depth ABOVE the print (does not move open)
  - holders → pro-rata airdrop by auction holdings
  - creator wallet (visible in recon up front)
  - burn
- `settleDustSurplus` sweeps residual dust after positioning.
- Realized κ = P / avg-sale-price is emitted; κ > κ̂ → surplus (appreciation
  dividend); κ < κ̂ → shortfall, covered by single-sided fallback (warned).

### 8.2a STONKZ4663 side pool

At settle, **5% of LP-designated tokens** (the tokens sized for LP pairing, not
of total supply) are set aside and deposited into a STONKZ4663 / userToken v4
pool as a **SINGLE-SIDED range**:

- **bottom** = 1 tick above the graduation price expressed in STONKZ4663 terms:
  `gradPriceUsd / stonkz4663SpotUsd`, rounded to the next usable tick above.
- **top** = 1000× bottom (tick-math edges respected).

Dump-immunity is a design property: the position starts with **zero STONKZ4663
exposure**, so a post-graduation dump of the user token cannot pull STONKZ4663
out of the position.

**Pre-genesis:** launches that settle before the STONKZ4663 genesis pool exists
park the side-pool tokens (+ any associated funds) in the BuybackAccumulator.
Permissionless `deploySidePool()` creates the position once the genesis spot is
readable.

### 8.3 BuybackAccumulator

Immutable. Holds: (a) the 5% pair-currency carve from every settle, (b) main-pool
pair-currency fees routed by FeeLocker (§8.6), (c) pre-genesis side-pool parking.
Keeper-cranked, **bounded** STONKZ4663 buys: per-crank size cap + cooldown,
hardcoded at construction (no admin knobs). Purchased STONKZ4663 is **burned**.

### 8.4 Reserve delivery

- **creatorReserve** (token-side): delivery mode chosen **at filing**
  (`INSTANT` | `VEST(duration, linear rate)`), immutable, visible in recon from
  block one. `INSTANT` still passes a **10-minute timelock** at graduation claim
  (grief / fat-finger window). `VEST` streams at exactly the committed rate.
- **treasuryReserve** (raise-side, if opted): delivers at settle.
- Events for all transitions (filed / unlocked / vested-chunk / delivered).

### 8.5 Declared-use (optional transparency)

Filing accepts an immutable short string per reserve (`declaredUse`, may be
empty). Emitted in the filing event, rendered in recon and on the token page.
**Not validated or enforced** — pure transparency surface.

### 8.6 FeeLocker + primary-pool hook fees (M4 supersedes main-pool routing)

Immutable custody for every position we create. **Side-pool compounding is
unchanged.** Primary-pool *ongoing* fee routing is superseded by M4:

| Pool | Ongoing fees |
|---|---|
| Main (primary) | **StonkzFeeHook** (see `docs/fees-and-governance.md` §1): per-swap fee-take + best-effort conversion of the token-denominated half to pair currency in the same tx via the same pool; split **80% feeReceiver / 20% protocolTreasury**. Receivers never hold token fees. Conversion failure → accrue + permissionless crank; **user trade never reverts from hook fee logic.** |
| Side | Fees compound back into the same position via permissionless crank (thickens over time) |

Settle-time 5% pair-currency carve → BuybackAccumulator (§8.1 / §8.3) remains.
FeeLocker **v2** integrates hook accounting for new launches; M3 v1 lockers on
already-launched tokens are left immutable (no migration).

### 8.7 Pool lifecycle (both pools)

- **Initialize** at the earliest moment the price basis exists:
  - main pool: auction construction at the floor tick
  - side pool: at `deploySidePool()` (or settle, if genesis spot is already live)
- `settle()` / `deploySidePool()` **sync spot to target** with a bounded swap
  budget before adding liquidity. Overrun → **retryable revert** (caller retries
  with a fresh budget / after the market moves).
- Front-creation of either pool key is an **expected attack**; the sync-to-target
  step is the defense (see suite C1).

Deployed contracts are immutable. No upgradeability.

### 8.8 Direct-to-DEX (see `docs/fees-and-governance.md` §2)

`$4k` / `$8k` start-mcap tiers; 95% listing supply → single-sided
`[startTick, MAX_TICK]` into FeeLocker + hook; 5% → STONKZ4663 side pool;
creatorReserve / declaredUse / INSTANT|VEST identical to auction. Rug-impossible
by construction; emergent tier volatility is a feature.

### 8.9 Checkpointed token + CTO (see `docs/fees-and-governance.md` §3–§4)

Launch tokens are ERC20Votes-style (past-block snapshots). Per-token CTO:
≥1% initiate, 24h vote, ≥0.1% to cast, power = min(snapshot, now) with paged
re-clamp, pass at 80% of frozen eligible denominator, early-fail when reject
makes passage impossible, finalize transfers feeReceiver + page admin only;
7-day cooldown on fail; voluntary feeReceiver transfer blocked while vote active.

## 9. Invariants (Foundry suite — differential-test all against reference/engine.js)

1. **Conservation**: at settle (100% LP default), wei-exact post-sweep:
   `sold + mainPaired + sidePoolTokens + surplusRouted + excessRouted + creatorReserve == launch supply`.
2. **Solvency**: top-ups only with positive guard slack; reserve sales never cause insolvency.
3. **Gate**: price advances iff scheduled quantity sold; never advances on partial/topup-only sales.
4. **Per-capita**: equal committed capital ⇒ equal fills; weight ratio == (c2/c1)^α exactly.
5. **One share per address**: N positions from one address fill identically to 1 position of equal total weight basis.
6. **Wallet cap**: address total never exceeds cap; capped leftover claimable at end.
7. **Committed bids**: no path reduces a position's budget except fills; priced-out ⇒ full unspent claimable; spent ≤ budget.
8. **Refund-all on failure**: below threshold ⇒ every position's full budget claimable; auction can never be drained.
9. **Settlement atomicity**: settles fully or reverts fully; terminal states mutually exclusive.
10. **Weights**: Σ = 1, monotone, 40/60 phase split, seamless handoff — for all N.

## 10. Security posture (see docs/launch-plan.md for full ladder)

Guarded launch: per-auction raise cap (~$50k) + global TVL cap → Foundry
fuzz/invariant + differential suite → Code4rena/Sherlock contest pre-revenue →
day-one bounty → burner-address mainnet dress rehearsal (unannounced, exact
production code, scripted one-command deploy) → **fresh production redeploy**,
admin roles to hardened keys at construction, deployer ends powerless. Genesis
($STONKZ4663) runs only on final contracts. Tier-1 audit at ~$1M fees removes
caps publicly.

### 10.1 M3.5 — real Uniswap v4 integration (required before testnet)

M3 lands settlement against a minimal internal v4 surface + mock PoolManager so
routing / state-machine / conservation suites (C4–C6) can gate. Pool-seam (C1)
and side-pool economics (C2) suites are **provisional when green on mocks** —
those suites exist precisely to catch where our model of v4 is wrong. C3
(BuybackAccumulator) is **partially provisional**: crank bounds / cooldown /
burn / pre-genesis park gate on mock; the **conversion path** uses 1:1 mock
pricing until re-validated against a real pool.

An M3.5 integration pass that vendors real `v4-core` (+ periphery as needed)
must, before any testnet deploy:

1. Re-run C1 and C2 **unmodified** against the real PoolManager
2. Assert **price-setting ratio** (`tokens × P == usd`) with a **named test
   against real v4** (mock: `test_C5_priceSettingInvariant`)
3. Keep / re-run **`test_C5_naiveFullRangeUnreachable`** (full-range all-tokens
   deposit unreachable) against real v4 — already exists under that name
4. Re-validate C3's conversion path against a real STONKZ4663 pool

The C1/C2 harness is dual-backend from day one. M3.5 may run in parallel with
Milestone 4. M4's hook suite (fees-and-governance C1) is likewise provisional on
mock and **must re-run unmodified against real v4-core in M3.5**. Separate
deployment-ladder preconditions (factory token custody at construction;
production filings revert on `liquidityStrategy == address(0)`) also block
testnet — see `docs/launch-plan.md` §8 and `docs/settlement.md`.
