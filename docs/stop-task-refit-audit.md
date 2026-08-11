# STOP — PREDEPLOY-REFIT Phase 0 (ruling-vs-code audit)

**Branch:** `feat/predeploy-refit` (from `main` @ `a281adf`)  
**Remote:** `https://github.com/trudeaudm/stonkz.green.git`  
**Held:** `feat/launch-deploy` @ `3fcdf74` (re-point after this merges)  
**Scope:** Read-only. No fixes without David ruling on PARTIAL/MISSING rows.  
**STOP:** Await rulings before Phase 1–3.

## Calibration (prompt-known)

| Item | Tag | Notes |
|---|---|---|
| BuybackAccumulator vs manual-DCA / buy-and-burn | **PARTIAL** | Park/release + manual `receiveFees` live; `crankBuyAndBurn` is **1:1 mock** (no pool swap, no transfer to `burnSink`). See R-ACC below. |
| Express immutable child refs vs stamp/settable modularity | **MISSING / VIOLATES** | Factory freezes `poolManager`, `feeLocker`, `hook`, `accumulator`, `ctoGovernor`, `pairToken`, `stonkzRef` as immutables. No owner setters. Conflicts with `[D] 2026-08-08` modular replaceability + genesis repoint. |

---

## Audit table (contract-behavior [D] clusters)

| ID | Ruling (summary) | Tag | Evidence | Suggested ruling ask |
|---|---|---|---|---|
| R-SW | DeployControls switches: off/on/allowlist; createSidePool; sidePoolBps; liquidityLocked stamp; NOT renounceable | **VERIFIED** | `DeployControls.sol:30–159`; `DeployControlsPhase1`, `SidePoolSwitchesPhase2`, `LockStampPhase3`, `SwitchDrillPhase4` | — |
| R-FEE | Main LP0 + hook 100bps; side LP 3000; pair-currency take; accrue-and-flush; custom fee; BeforeSwapDelta | **VERIFIED** | `StonkzFeeHook.sol:29–31,217–264`; `StonkzDirectListing.sol:39–40`; `LadderSettlement.sol:25–26`; `FeePhase3`, `FeeHookPhase1` | — |
| R-V4 | Production bind RH PoolManager via V4Adapter + flag-mined hook | **PARTIAL** | Adapter+hook+fork tests on main (`V4Adapter.sol`, `ForkCanonPhase4`). Official `Deploy.s.sol` on **this branch** is empty stub (`script/Deploy.s.sol:32–37`). Full script lives on `feat/launch-deploy` only. | Confirm Phase 4 of this chain re-points from launch-deploy after merge (planned). |
| R-CARVE | carveBps mutable factory default, stamped per auction | **VERIFIED** | `StonkzLadderFactory.sol:14–50`; `StonkzLadderAuction.sol:33,200`; `test_P3_carveBps_stampSurvivesDefaultChange` | — |
| R-LAD | Ladder: time rungs; bids≠swaps; permissionless settle; vectors | **VERIFIED** | `LadderConstants`, `StonkzLadderAuction.sol:245+,476–480`; A1–A5 vectors Real+Mock | — |
| R-VAULT | StonkzVault holdback + direct-release + paths | **VERIFIED** | `StonkzVault.sol`; vault Phase0/1/2 tests; factory holdback gate | — |
| R-VAN | Vanity `0x4663` on factory CREATE2 listings/auctions/tokens | **MISSING** (on this branch) | Express/Ladder on main: CREATE2 salt bind **without** `Vanity.requirePrefix`. Hook vanity **is** enforced (`HookVanity.sol`). Prefix enforcement exists on `feat/launch-deploy` only. | Bring vanity from launch-deploy in re-point, or re-state rule as hook-only? |
| R-REF | `stonkzRefPriceWad` pair-wei/STONKZ; RefPriceUnset | **VERIFIED** | `DeployControls.sol:15–26,163–190`; `test_ref_*` | Phase 1 will rename/rekey — awaiting GO |
| R-GEN | GENESIS VIA PLATFORM: stand-in ref; no STONKZ pre-mint in Deploy | **PARTIAL** | Ruling in local `docs/03`. Implemented on **`feat/launch-deploy`**; **not** on main (stub Deploy; `StonkzToken` still mints 100M). | Re-point after merge (planned). |
| R-ACC | BuybackAccumulator = manual DCA buy-and-burn (Layer 3) | **PARTIAL** | `BuybackAccumulator.sol:3–7,58–97`: park live; crank mock 1:1. Express still parks when `stonkz4663==0` (`StonkzDirectListing.sol:219–224`). | Phase 2 rebuild per 2026-08-11 spec (await GO) |
| R-MOD | Modular replaceability: owner-settable cross-contract refs | **PARTIAL** | Ladder: `setVaultRef`, auction `setSettlement`, settlement `setStonkzRef`/`setFeeLocker`. Express: **all service refs immutable**. | Phase 1 settable refs (await GO) |
| R-STAKE | Staking / emissions / team vesting | **MISSING** | No contracts under `src/` | Confirm still non-launch-gate / out of this chain |
| R-CTO | CTO system (1%/0.1%/80%, candidate immutable) | **VERIFIED** | `CTOGovernor.sol`; wired via Express listing + FeeHook; `CTOAdversarial.t.sol`, `CrossModelParity` | See orphan note — product surface vs launch-critical |
| R-SYBIL | Public “protection against sybil,” no numeric claims | **VERIFIED** (copy) | Docs/process; not a contract assert | — |
| R-BOUNTY | SECURITY.md + tiers launch gate | **PARTIAL** | Present on `feat/launch-deploy`; **not** on main tip | Land via launch-deploy merge/re-point |
| R-L3CAP | Protocol fee share of hook fee — STONKZ Layer-2 “100% of fee” vs DEFAULT 25% | **PARTIAL** | Hook `DEFAULT_PROTOCOL_FEE_BPS = 2500` (25% of hook fee to treasury path). Early tokenomics Layer-2 “100% of fee” for STONKZ pool not stamped as a special case. | Clarify whether STONKZ pool needs a special protocolFeeBps stamp |

---

## Orphan architecture sweep

| Asset | What it is | Wired? | Tested? | Tag | Notes for David |
|---|---|---|---|---|---|
| **CTOGovernor** | Per-token CTO vote → `governorTransfer` on fee receiver | Yes — Express listing registers; FeeHook gates | Yes — `CTOAdversarial`, parity | **LIVE** | Ruled early (`docs/03` CTO). Not launch-path critical for Phase 4 drills, but **not** orphan. |
| **FeeLocker.sol (V1)** | Pre-V2 locker; main crank retired; side compound | Legacy strategy + older tests still import | `SidePoolEconomics`, `FeechainE2E`, etc. | **ORPHAN / RETIRE** | Still in `contracts/src/` beside `FeeLockerV2`. Production Express/LadderSettlement use **V2**. Candidate: move to `legacy/` or delete after test migration. |
| **BuybackAccumulator park/strategy** | One-shot `setStrategy`; `parkSidePoolTokens` | Express pre-genesis path | `BuybackAccumulator.t.sol` | **ORPHAN-ISH** | Pre-FEECHAIN parking design; Phase 2 must retire or fold explicitly. |
| **StonkzToken (on main)** | 100M mint to custody | Deploy stub does not call it | Minimal (`ForkCanonPhase4`) | **SUPERSEDED** | GENESIS VIA PLATFORM supersedes; contract may remain for tooling but must not be in official Deploy. |
| **CreatorReserveLib** | Lib used by DirectListing | Via listing | No direct unit test | **OK** | Indirect coverage. |
| **LadderWeights** | Auction weights | Via auction | Indirect via ladder vectors | **OK** | |
| **Deploy.s.sol (main)** | Empty `run()` | N/A | Soft-launch helper only | **STUB** | Real script on launch-deploy. |

---

## BuybackAccumulator detail (calibration)

```
crankBuyAndBurn (L82–97): burned = pairSpent;  // mock 1:1 — no Uniswap swap, burnSink unused
parkSidePoolTokens: still called from StonkzDirectListing when stonkz4663 == address(0)
```

Phase 2 target (per prompt): rebuild to fund→crank(pct)→swap→burn-to-dEaD with keeper ACL, interval, slippage, hostile-keeper bound.

---

## Express immutables detail (calibration)

`StonkzExpressFactory.sol:18–25` immutables: `poolManager`, `feeLocker`, `hook`, `accumulator`, `ctoGovernor`, `pairToken`, `stonkzRef`.  
Stamped into each `StonkzDirectListing` at `list`. **Cannot** owner-repoint for genesis stand-in→real STONKZ on Express without factory redeploy (LadderSettlement *can* `setStonkzRef`).

---

## Phase 0 STOP — rulings requested

Before Phase 1 (settable refs + rename) or Phase 2 (accumulator v2):

1. **R-MOD / Express immutables** — Approve Phase 1 settable-ref pattern for Express (and Ladder settlement/sideTokenRef)?
2. **R-ACC** — Approve Phase 2 accumulator rebuild; retire vs fold park path?
3. **FeeLocker V1** — Move to `legacy/` / delete after test retarget to V2?
4. **R-VAN** — Vanity on listings/auctions: require from launch-deploy, or defer?
5. **R-STAKE** — Confirm out of scope for this chain?
6. **R-L3CAP** — Any STONKZ-special protocolFeeBps, or default 25% OK through genesis?
7. **R-GEN / R-V4 / R-BOUNTY on main** — Confirm “land via launch-deploy re-point after this merges” (no duplicate work on this branch until then)?

**No Phase 1–3 code until you rule.** Gate CLOSED for broadcast. `feat/launch-deploy` stays at `3fcdf74`.
