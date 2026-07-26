# Fees, Direct Listing & CTO Governance — Milestone 4

> Companion to `docs/mechanism-spec.md`. Auction-engine math (§2–§7) is untouched.
> Primary-pool fee routing here **supersedes** M3 §8.6 for the main pool;
> side-pool compounding (§8.6 Side row) is unchanged.

## 0. Competitive decision (on record)

**v1 primary-pool fees are hook-based per-swap conversion** — Doppler/Bankr
parity, deliberate. Receivers never hold token-denominated fee clips; there is
nothing to "dump." Continuous conversion inside the swap is the product
posture, not a later optimization.

## 1. Fee architecture — primary pool (both launch models)

### 1.1 Hook take + convert

On each swap in the primary (pair ↔ userToken) pool, the v4 hook:

1. Takes the protocol/swap fee.
2. Converts the **token-denominated half** to the pair currency (ETH/USDG)
   within the **same transaction** via the **same pool**.
3. Splits all pair-currency fee proceeds 80/20 (below).

No human ever custodies token-denominated fees. Receivers only ever see pair
currency. No accumulated fee clips exist to dump.

### 1.2 Hook discipline (non-negotiable; top of M3.5 audit scope)

The hook does **fee-take, one bounded conversion, split accounting — NOTHING
else.**

- **Conversion is BEST-EFFORT.** Any internal-swap failure accrues fees for
  later conversion via bounded permissionless cranks (the fallback path). The
  **user's trade ALWAYS succeeds** — a trade may never revert due to hook fee
  logic.
- **Reentrancy posture:** conversion re-enters the same pool. Use v4-native
  patterns; study Doppler's public hook source as the reference implementation
  on Robinhood Chain. Document the chosen pattern in NatSpec + this doc's
  appendix when implemented.

### 1.3 Split

```
converted_fees + pair_currency_fees
  ├── 80% → feeReceiver   (initially the creator)
  └── 20% → protocolTreasury  (hardened address; buybacks, operations —
                               discretionary by design, documented)
```

Wei-exact. Side-pool fees continue to **compound into the same position**
(M3 §8.6 Side — unchanged).

### 1.4 feeReceiver transfer

| Path | Rule |
|---|---|
| Voluntary | Current holder may transfer anytime |
| Blocked | While a CTO vote is **active**, until `finalize` |
| CTO | On successful finalize, feeReceiver (+ token-page admin) transfers to the **candidate** recorded at initiation |

### 1.5 FeeLocker v2

New launches use **FeeLocker v2**, which integrates hook accounting (accrual
fallback + crank routing into the 80/20 split). Per-token immutability: tokens
already launched under M3 FeeLocker v1 keep v1; versioned replacement note only
— no migration of live positions.

M3 main-pool routing (pair → BuybackAccumulator / user-token → burn) is
**superseded for new primary pools** by this hook architecture. The settle-time
5% pair-currency carve → BuybackAccumulator (§8.1 / §8.3) remains.

---

## 2. Direct-to-DEX (`StonkzDirectListing`)

### 2.1 Filing

- Creator picks start mcap tier: **$4k** or **$8k**. No raise, no auction.
- `creatorReserve`, `declaredUse`, filing-time vesting (`INSTANT` 10-min /
  `VEST`) identical to auction filings. **INSTANT** tag on all surfaces.

### 2.2 Liquidity

```
95% of listing supply → single-sided v4 range [startTick, MAX_TICK]
                        (start mcap → infinity)
                        position burnt into FeeLocker custody
                        StonkzFeeHook (§1) attached at pool creation

5%  of listing supply → STONKZ4663/token single-sided range
                        [startPrice + 1 tick, 1000×]
                        fees compound into the position (unchanged)
                        pre-genesis parking + permissionless deploySidePool()
```

### 2.3 Protocol take on directs

= the **5% token carve** + the **20% fee share**.  
No funds carve — no raise exists.

### 2.4 Properties (document + test)

1. **Rug-impossibility by construction** — no withdrawable principal liquidity;
   no raised funds. Enumerate and assert no code path withdraws principal.
2. **Emergent tier volatility** — same depth curve; lower start mcap ($4k vs
   $8k) ⇒ steeper price impact for an identical buy. A feature, not a
   parameter.

### 2.5 Conservation

```
listed + sidePoolTokens + creatorReserve == total supply   (wei-exact)
```

---

## 3. Checkpointed launch token

The standard launch token (both models) is an **ERC20Votes-style** token with
balance checkpoints. Voting reads use **past-block snapshots** (flashloan-immune).

Wired into both IPO and Direct factories at mint.

---

## 4. CTO governance (per token, both models)

### 4.1 Initiate

- Any address holding **≥ 1% of at-large supply**, via the token page;
  eligibility enforced on-chain.
- Takes an explicit **candidate** (beneficiary) address: default = initiator;
  may be any address (e.g. a community multisig). The vote is defined as
  **"transfer feeReceiver + page-admin to \<candidate\>"**. Candidate is
  **immutable per vote**, emitted in the initiation event, rendered on the
  token page and all voting surfaces.
- Records the **initiation snapshot block**.
- **Eligible denominator** =  
  `total − LP-held − burned − protocol-parked`  
  with **unvested `creatorReserve` INCLUDED**.  
  Computed **at the initiation snapshot** and **FROZEN** for the vote.

### 4.2 Vote (24-hour window)

- Minimum **0.1% of at-large supply** to cast.
- Support or reject.
- Power = `min(balance @ initiation snapshot, balance @ vote tx)`.
- Every vote transaction **re-clamps ALL prior voters' powers** to
  `min(recorded, balance-now)` — paged with a per-tx work cap.
- Voter set bounded (**≤ 1000**) by the 0.1% minimum; gas borne by the voter.

### 4.3 Pass / early-fail

- **PASS:** adjusted SUPPORT ≥ **80%** of the frozen eligible denominator.
- **EARLY-FAIL:** terminate immediately when adjusted REJECT makes passage
  mathematically impossible (REJECT > 20% of frozen denominator).

### 4.4 Finalize

- Permissionless after window or early-fail; one final re-clamp.
- On success: transfers **feeReceiver + token-page admin** to the **candidate**
  (immutable beneficiary recorded at initiation — not necessarily the
  initiator).  
  **Nothing else** transfers (reserves, vesting, LP untouched).

### 4.5 Cooldown (restructured)

- **Per-address 7-day cooldown** binds the **failed initiator** and the
  **failed candidate** (either role re-appearing as initiator *or* candidate
  within 7 days reverts initiation).
- **Per-token spacing:** only **24 hours** between vote windows.
- **Rationale on record:** a per-token 7-day cooldown let a hostile 1%
  squatter serially lock out genuine community efforts; per-address cooldown
  prices retries at a fresh 1% of supply each.

### 4.6 Protective rationale (verbatim)

Abstention functions as a veto (the creator-side-wallet example). CTOs of
genuinely dead tokens failing is **INTENDED**. The voluntary-transfer path
covers cooperative handoffs.

### 4.7 Events

Every transition emits (initiate with initiator+candidate / vote / re-clamp
page / early-fail / pass / finalize / address-cooldown / token-spacing /
voluntary-transfer-blocked). Token page renders the full lifecycle.

---

## 5. Cross-model parity

Identical fee + CTO behavior for auction-launched and direct-listed tokens.
Parameterized suites run both.

---

## 6. Suite map (M4-C)

| ID | Focus | Backend / note |
|---|---|---|
| C1 | Hook: fee-take + conversion; best-effort; reentrancy; never revert trade; receiver never gets tokens; 80/20; gas; side-pool unaffected | **provisional on mock** — re-run unmodified vs real v4 in M3.5 (same dual-backend harness) |
| C2 | Direct: MAX_TICK range; rug-impossibility; tier volatility; conservation | gate |
| C3 | CTO adversarial (named attacks) | gate |
| C4 | Cross-model fee + CTO parity | gate |
| C5 | Conservation + invariants re-run; auction vectors byte-unchanged | gate |

---

## 7. M3.5 interaction

M4 C1 (hook) is provisional on mock v4 and **REQUIRED** to re-run unmodified
against real `v4-core` in M3.5 before testnet — same dual-backend harness as
M3's C1/C2. M3.5 may run in parallel with M4.
