# STOP — Side-pool init price / `stonkzRefPriceWad` denomination
**Branch:** `feat/factory-switches`  
**Scope:** Phase-3 ADDENDUM — stamped `stonkzRefPriceWad` for Express + Ladder side-pool init.  
**Status:** STOPPED pending denomination ruling. **No conversion code landed.**  
**Trigger:** Prompt gate — *"IF printP or startPriceWad is denominated in ETH rather than USD, the conversion needs the pair leg too — STOP and report the actual denomination rather than guessing."*

---

## Verdict

`startPriceWad` / `printPrice` are **pair-currency per token (WAD)**, not a USD oracle unit.
Pair may be USDG **or** native ETH (`address(0)`). Dividing by a USD-labeled
`stonkzRefPriceWad` ($0.001 = `1e15`) is dimensionally sound only when pair ≈ USD.
ETH-pair paths need an explicit ruling before the stamp lands.

---

## Code evidence (operands)

| Site | What the unit actually is |
|---|---|
| `StonkzDirectListing.startPriceWad` | Comment: `// pair per token`. Set as `startMcap * WAD / totalSupply`. |
| `StonkzDirectListing` tiers | `TIER_4K = 4000e18`, `TIER_8K = 8000e18` — dollar *labels*, but pair is constructor arg. |
| `DirectListing.t.sol` | `PAIR = address(0) // native pair` with those same $4k/$8k tiers. |
| `LadderConstants` | `Money = pair-currency wei (WAD dollars when pair is 18-dec USDG/ETH quote). Prices = pair-per-token in WAD.` |
| `StonkzLadderAuction.floorMcap` | Comment `// WAD dollars`; `floorPrice = floorMcap * WAD / supply`; `pairToken` may be `address(0)`. |
| Ladder phase tests | Native pair + `floorMcap: 2_500 ether` / `5_000 ether` (dollar fiction in ETH wei). |
| `LadderSettlement._buildSidePool` | Passes `printP` straight into `_sqrtPriceFromPriceWad` as if pair == STONKZ (bug this addendum fixes) — no USD conversion today. |
| Express `_deploySidePool` | `spot = WAD` ($1 mock); `priceInStonkz = startPriceWad * WAD / spot` — assumes startPriceWad shares the mock's dollar unit. |
| Mechanism / ledger | Spec §0: dollars (USDG). docs/03: genesis ~$100k FDV ⇒ **$0.001/token** (aligns with mid-band `1e15`). |

**Bottom line:** semantic money is "WAD dollars" when the quote is treated as dollar-like; the stored type is always **pair/token**. Production + tests both allow ETH as pair.

---

## Why the proposed formula is unsafe without a ruling

Proposed:
```
priceInStonkz = startPriceWad * WAD / stonkzRefPriceWad
```
with `stonkzRefPriceWad` launch default `1e15` // **$0.001**.

| Pair | `startPriceWad` / `printP` | `stonkzRefPriceWad` as $ | Result |
|---|---|---|---|
| USDG | ≈ USD/token | USD/STONKZ | STONKZ/token ✓ |
| Native ETH | ETH/token | USD/STONKZ | **wrong units** — needs ETH/USD (or ref stamped in ETH) |

Mispricing low still drains the side pool; guessing an ETH/USD leg here would be mechanism invention.

---

## Ruling options (pick one)

**A. USDG-only for side-pool price math (recommended if genesis quote is USDG)**  
- Assert / document: side-pool init assumes pair is dollar-stable (USDG).  
- ETH-pair listings: either disallow side pool, or park until a pair-leg exists.  
- Stamp `stonkzRefPriceWad` as WAD **USD** (= pair units under A). Formula as written. Launch `1e15`.

**B. Ref is pair-per-STONKZ (unit-matched to prices)**  
- Rename semantics: `stonkzRefPriceWad` = **pair currency per STONKZ**, not an independent USD oracle.  
- Launch `1e15` valid when pair is USDG (0.001 USDG/STONKZ ≈ $0.001).  
- ETH-pair: owner sets a different default in ETH/STONKZ before those deploys (or ETH factories carry their own default).  
- Same formula; no second leg. Closest to existing "WAD dollars when quote is dollar-like" discipline.

**C. Dual-leg for ETH pairs**  
- Keep USD ref + require `pairRefPriceWad` (ETH/USD) when `pairToken == address(0)`.  
- `priceInStonkz = startPriceWad * pairRefPriceWad / stonkzRefPriceWad`.  
- Larger surface; overlaps the queued post-genesis TWAP upgrade.

---

## Already ruled (not in dispute)

- Stamp pattern (5th application): factory mutable default → immutable per deploy.  
- Launch default mid-band `1e15` ($0.001), bounds `[1e12, 1e21]`, `RefPriceChanged`.  
- Err high, never low (asymmetric drain).  
- QUEUE (docs/04, local): post-genesis TWAP from live STONKZ/ETH — not this chain.

## Not done (blocked)

- DeployControls / Express / Ladder stamp + conversion.  
- Known-value init-tick tests; stamp-survives-default-change.  
- WIP Phase 3 lock-stamp work on this branch is **unrelated** and left uncommitted.

## Ask

Which option **A / B / C** (or amend)? After ruling, implement stamp + conversion + tests on this branch without guessing an ETH/USD leg.
