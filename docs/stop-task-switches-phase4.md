# STOP — Factory switches Phase 4 (reconciliation)
**Branch:** `feat/factory-switches`  
**Status:** Phase 4 complete. Pushed. **NO MERGE** — awaiting David merge ruling.  
**RIDER B:** Accepted under refined gate (ruling 2026-08-10).

---

## RIDER B — three mandatory conditions

### 1. Vector JSONs byte-identical vs `main` — PASS
All `contracts/test/vectors/ladder/*.json` (10/10) **SAME** `git hash-object` vs `main:`.  
Also confirmed: `contracts/test/fixtures/ladder/*.json` (harness inputs from gen script) **SAME**.  
`LadderVectorLoader.sol` **SAME**.

### 2. Per-hunk value review — PASS (behavior-preserving)

| File | New literals | Verdict |
|---|---|---|
| `LadderPhase1.t.sol` | `createSidePool: true`, `stonkzRefPriceWad: 2.5e11` | Preserving — pairToken=`address(0)` ⇒ ETH default; fixtures `sidePoolBps=500` (= source `sidePoolPct=5`) |
| `LadderPhase2.t.sol` | same ×2 sites | Same |
| `LadderPhase3.t.sol` | Params: same; SettleArgs: `createSidePool: true`, `sidePoolBps: 500`, `stonkzRefPriceWad: 2.5e11`, `liquidityLocked: true`, `unlockRecipient: CREATOR` | Preserving — ETH pair in auction Params; lock fields inert when locked (no withdraw in vector path); unlockRecipient stamped creator |
| `LadderPhase4Base.sol` | `createSidePool: true`, `stonkzRefPriceWad: 2.5e11` | Preserving — pairToken=`address(0)` |
| `LadderTolerance.sol` | **comment only** | Quote: `// 1e-9 WAD dollars` → `// 1e-9 pair-currency WAD` — constant `MONEY_ABS_FLOOR = 1e9` **unchanged** |

**Zero assertion / tolerance-value hunks.** No expect/assert body changes vs `main`.

### 3. A1–A5 × 10 GREEN — PASS
`forge test --match-contract "LadderPhase1|LadderPhase2|LadderPhase3"` (vector A suites):  
**29 passed, 0 failed** — Phase2 A2_01–10, Phase3 A1A5_01–10 all PASS.

---

## RIDER B AMENDMENT (all future chains)

> Byte-identical discipline applies to `contracts/test/vectors/**/*.json` (ground truth).  
> Harness `.t.sol` changes are permitted only as **ABI-literal hunks** under **per-hunk value review**.  
> Assertion / tolerance-value edits remain STOP.

Recorded here and in `docs/15-switches-report.md` ledger close-out.

---

## PHASE-4-GO mandatory items 2–3

### Lock stamp read-once
- `test_P3_express_readOnce_lockedSurvivesFactoryUnlock` — withdraw still reverts after factory unlock  
- `test_P3_express_readOnce_unlockedSurvivesFactoryRelock` — withdraw succeeds after factory relock  
- `test_P3_ladder_readOnce_lockedSurvivesFactoryUnlock` — auction stamp immutable (msg.sender path)  
- `test_P3_ladder_settlement_readOnce_*` — SettleArgs stamp gates withdraw, not live factory  

### Refprice evidence (`SidePoolRefPrice.t.sol` — 12/12 PASS)
- ETH `2.5e11` / USDG `1e15` known-value init ticks  
- `RefPriceUnset` when createSidePool + unset  
- Stamp survives default change (Express + Ladder)  
- Bounds + loud `RefPriceChanged`  
- UNITS comments: pair-wei per STONKZ token, WAD  

---

## Phase 4 reconciliation

| Check | Result |
|---|---|
| Switch-drill (`SwitchDrillPhase4`) | PASS — off/on, allowlist, side toggle, lock coexistence, custom-fee 300 bps, carve stamp |
| FEECHAIN / HookFees / MockVsReal / FeePhase3 | PASS |
| VaultPhase0–3 | PASS |
| DirectListing C2 (incl. rug) | PASS |
| Deploy gas (branch) | Express `list` ≈ **4,852,794**; Ladder `file` ≈ **29,315,116** (Express path net-new vs main; Ladder includes DeployControls + stamps) |
| Coverage (switch suites, `--ir-minimum`) | DeployControls 87% lines; ExpressFactory **100%**; DirectListing 77%; LadderSettlement 83%; LadderFactory 71%; FeeLockerV2 60% (withdraw registry paths) |

---

## Docs
- `docs/15-switches-report.md` (gitignored `docs/[0-9][0-9]-*.md`) — STATE FOR MERGE RULING  
- `docs/04` (gitignored) — side-pool bounds + allowlist OPEN → RESOLVED; RIDER B amendment recorded  

## Merge ruling requested
Approve merge of `feat/factory-switches` → `main`? **Do not merge without explicit YES.**
