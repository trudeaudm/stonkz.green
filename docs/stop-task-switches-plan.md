# STOP — Factory switches Phase 0 (placement plan)
**Branch:** `feat/factory-switches`  
**Ruling basis:** docs/03 "[D] 2026-08-03 STONKZ TOKENOMICS / Factory switches"  
**Prompt rulings in force:** stamp pattern; sidePoolBps bounds [0, 2000] default 500;
allowlist NOT renounceable (purpose = factory migration); loud events; bps units
discipline.  
**Status:** Phase 0 only. **NO implementation.** Placement needs David ruling.

---

## 1. Deploy-surface map (as of `main` @ bcb0639)

| Path | Entry today | Factory? | Side pool | Lock / custody |
|---|---|---|---|---|
| **Express** | `new StonkzDirectListing(...)` from tests / callers | **NONE** | Hardcoded `SIDE_BPS = 500`; park if `stonkz4663 == 0`, else deploy | `FeeLockerV2.lockPosition` after listing calls `modifyLiquidity`. **No withdraw.** Rug test = no principal path + buckets immutable. |
| **Ladder** | `StonkzLadderFactory.file(Params)` → `new StonkzLadderAuction` | **YES** (`StonkzLadderFactory`) | `Params.sidePoolBps` (filer-supplied; `LadderConstants.SIDE_POOL_BPS = 500` is the grid default). Settlement: `sideAmt > 0` → build if `stonkzRef != 0`, else `SidePoolParked` | **No FeeLocker.** `LadderSettlement` itself calls `modifyLiquidity` (positions keyed by settlement as `msg.sender`). **No withdraw.** |

Legacy (`StonkzAuction` / Manager / `StonkzLiquidityStrategy` waterfill path): **out of scope** — retired / not in deploy manifest.

### Express answer (prompt question)
Express does **not** route through a factory today. It is a direct constructor deploy.
A production allowlist / `deploysEnabled` gate **cannot** bind Express without adding an
Express factory (or an equivalent external gate checked in the constructor). Ladder
already has a filing gate.

---

## 2. Prompt vs code tensions (placement-relevant)

1. **docs/03 says "the factory"** (singular) gains four switches. Reality = two launch
   surfaces, one of which has no factory.
2. **Lock stamp + FeeLocker withdraw** vs PoolManager ownership: mock (and v4 position
   identity) keys liquidity by `msg.sender` of `modifyLiquidity`. FeeLockerV2 never
   mints; Listing/Settlement do. A withdraw *inside* FeeLockerV2 cannot remove today's
   positions unless the mint path changes so FeeLocker is `msg.sender`.
3. **LOCKED = byte-for-byte today's behavior / existing tests unmodified:** mint-path
   change (Listing → FeeLocker mint) alters position IDs (`keccak256(msg.sender,…)`).
   Express rug test (`test_C2_rugImpossible_noPrincipalWithdraw`) does **not** assert
   position IDs — it asserts no principal claim path + immutable buckets. Ladder has
   **no** FeeLocker registration at all today.
4. **Ladder `sidePoolBps` already exists on Params** but is not a factory-default stamp;
   Express hardcodes 500. Switch 3 unifies to factory-default → per-token stamp.
5. **docs/04 OPEN items this chain closes (Phase 4 append):** side-pool share bounds;
   allowlist renounceability — prompt already rules both; ledger update at reconciliation.

---

## 3. Proposed ownership (ONE architecture — approve or amend)

### 3.1 Gate + defaults owner: each launch factory (identical surface)

| Switch | Mutable home | Stamp home | Notes |
|---|---|---|---|
| **4. `deploysEnabled` + allowlist** | `StonkzLadderFactory` **and** new `StonkzExpressFactory` | N/A (gate, not stamp) | Same semantics on both. Allowlist **not renounceable** (no `renounce` / no burn-owner that clears the feature). Purpose = factory migration: flip old factory `deploysEnabled=false`, stand up new factory. |
| **2. `createSidePool` (bool)** | factory default | Express: `StonkzDirectListing` immutable; Ladder: `StonkzLadderAuction` immutable (extend `Params`) | Genesis: `createSidePool=false` → zero side allocation; all LP-destined tokens stay on main (Express: `listed = listingSupply`; Ladder settlement: `sideAmt = 0`). No park bucket when false. |
| **3. `sidePoolBps`** | factory default, bounds **[0, 2000]** // bps of LP-destined tokens (0–20%), default **500** // 5% | Same stamp sites as (2) | Arithmetic unit test required. When `createSidePool=false`, stamped bps is recorded but **unused** (side amount forced 0) — holder still reads the stamp. |
| **1. `liquidityLocked`** | factory default **TRUE** | Express: listing immutable; Ladder: auction immutable; **also recorded on FeeLockerV2 at `lockPosition`** | See §3.3. |

**New contract:** `StonkzExpressFactory` — sole production deployer of `StonkzDirectListing`
(`listing` requires `msg.sender == factory` via immutable `factory` on the listing, or
constructor `onlyFactory` pattern). Tests that currently `new StonkzDirectListing` move
to `expressFactory.list(...)` **except** where a Phase 3 coexistence harness needs direct
construction with explicit stamp overrides (then still through factory with overrides).

**Shared code (not a third authority):** internal library or abstract `DeployControls`
with storage, inherited by both factories — **one implementation, two instances**.
Each factory's switches are independent (migration = disable instance A, use instance B).
No separate standalone "gate service" contract (avoids a third owner of the switches).

### 3.2 Allowlist semantics (Phase 1 — define explicitly)

```
deploysEnabled == false     → all deploys revert (DeploysOff), including allowlisted
deploysEnabled == true
  allowlist empty           → OPEN: any msg.sender may file/list
  allowlist nonempty        → only allowlisted addresses may file/list
```

Owner is always able to call setters; owner is **not** implicitly allowlisted unless
added. Events (loud): `DeploysEnabled(bool)`, `DeployerAllowed(address)`,
`DeployerRevoked(address)`. No renounce path for the allowlist feature.

### 3.3 Lock stamp + FeeLockerV2 change (THE architectural choice)

**Recommended (preserves LOCKED mint path / position identity):**

| Piece | Placement |
|---|---|
| Stamp | Immutable `liquidityLocked` on Express listing + Ladder auction (from factory default at deploy/file). |
| FeeLocker registry | `FeeLockerV2.lockPosition` gains `bool locked` + `address recipient` stored per `lockId` (and `token → lockIds` index). LadderSettlement **gains FeeLockerV2 wiring** and calls `lockPosition` after each LP mint (main cash, main ask, side) — registry only; mint `msg.sender` stays Settlement/Listing. |
| Withdraw (UNLOCKED only) | **Not** `FeeLockerV2` calling `modifyLiquidity` (cannot: wrong `msg.sender`). Instead: `withdrawPrincipal` on the **position owner** (`StonkzDirectListing` / `LadderSettlement`), which (1) requires `!liquidityLocked`, (2) requires `msg.sender == designatedRecipient` (stamp: creator at deploy, unless prompt amends), (3) performs negative `modifyLiquidity`, (4) emits e.g. `LiquidityWithdrawn`. FeeLockerV2 exposes `requireUnlocked(lockId, msg.sender)` / view helpers and flips `active=false` when notified — **or** listing/settlement is the sole withdraw entry and FeeLocker is view+invariant source. |
| LOCKED | No withdraw entrypoint callable successfully; existing Express rug test runs unmodified against default-locked factory deploy. Invariant fuzz: no call sequence extracts principal from locked stamp. |

**Why not "withdraw inside FeeLockerV2" literally?** Under current PoolManager position
keys, FeeLocker cannot burn liquidity it did not mint. Moving mint into FeeLocker would
satisfy the prompt wording but **changes position identity for LOCKED tokens too**,
risking "byte-for-byte / unmodified tests" and widening the diff beyond the stamp.

**Alternate (only if David overrides):** FeeLockerV2 becomes sole minter+locker+withdrawer
for both paths. LOCKED tests that ignore position IDs may still pass; any test or
off-chain tool keyed on listing/settlement as position owner breaks. Larger blast radius.

### 3.4 Designated recipient (needs one-line confirmation)

Propose: **token creator** (Express `ListingParams.creator` / Ladder `Params.creator`) is
the sole withdrawer when `liquidityLocked == false`. Not feeReceiver (CTO-movable).
Not factory owner.

### 3.5 What does NOT change

- Auction / settlement **math** (raise split, gates, rung pacing, fills, carve formula).
- Grid constants / floors / thresholds.
- Hook fee stamp path (already exists); custom-fee 300 bps remains hook-owner path.
- Legacy FeeLocker v1 — leave as-is (strategy path); **V2 is the Express + new Ladder
  settlement registry target**. (If Ladder must use V1 for some reason — STOP; V2 is the
  FEECHAIN Express locker.)

### 3.6 Carve / custom-fee (Phase 4 drill only)

Already stamped elsewhere (`carveBps` on Ladder factory; `hookFeeBps` on hook). Phase 4
switch-drill test **mirrors** rehearsal drills including custom-fee 300 bps + carve stamp
survival — no new carve/fee ownership in this chain.

---

## 4. Phase plan (post-approval)

| Phase | Work |
|---|---|
| 1 | `DeployControls` + Express factory; gate both `file` / `list`; events + tests for off / open / allowlisted |
| 2 | `createSidePool` + `sidePoolBps` defaults/stamps; genesis `createSidePool=false`; Express ratio no longer hardcoded constant for new deploys; settlement absence path; stamp-survives-default-change |
| 3 | `liquidityLocked` default true; FeeLockerV2 registry fields; LadderSettlement lock registration; unlock withdraw on Listing/Settlement; locked regression unmodified; coexistence + invariant fuzz |
| 4 | Full suite; switch-drill test; coverage/gas; `docs/15-switches-report.md`; docs/04 OPEN → RESOLVED for bounds + allowlist renounce |

---

## 5. STOP — decisions requested

Approve or amend before Phase 1 code:

1. **Express factory** (`StonkzExpressFactory`) as sole Express deploy path — YES/NO?
2. **Switches live on both factory instances** via shared abstract/lib (not a third gate contract) — YES/NO?
3. **Lock withdraw placement:** recommended (withdraw on Listing/Settlement, stamp+registry on FeeLockerV2, mint path unchanged) vs alternate (FeeLocker sole minter) — which?
4. **Designated recipient = creator** — YES/NO?
5. **`createSidePool=false` ⇒ side amount 0, mass to main LP** (no park) — YES/NO?
6. **Allowlist semantic** (empty+on = open; nonempty = gated; off = all blocked; not renounceable) — YES/NO?

No merge. No Phase 1 until placement ruled.
