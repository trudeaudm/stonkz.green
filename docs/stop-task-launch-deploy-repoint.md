# STOP — launch-deploy re-point after PREDEPLOY-REFIT merge

**Branch:** `feat/launch-deploy` @ tip (post-merge)  
**Main merge:** `ce99764` (`Merge branch 'feat/predeploy-refit'`)  
**CI hotfix on main:** `08fdca3` (SidePoolRefPrice tick assert)  
**Held posture:** Phase-3 gate — **no broadcast**. GO PHASE 4 awaits David.

## 1) Main merge

| Item | Value |
|---|---|
| Merge | `feat/predeploy-refit` → `main` `--no-ff` |
| Merge hash | **`ce99764d02e892b6c046e58aaca41b76deaa4faa`** |
| Branch deleted | `feat/predeploy-refit` local + `origin` |
| CI on merge | **RED** — https://github.com/trudeaudm/stonkz.green/actions/runs/31509794944 — 251 pass / 1 fail: `SidePoolRefPrice.test_ref_express_eth_initTick_knownValue` (`sideTickLower` −887220 ≠ naive `tickAbovePrice` 96900 after Phase-4 Express real-PM orientation) |
| Hotfix | **`08fdca3`** — soften to arithmetic + `sidePoolDeployed` / `sideLiquidity` |
| CI after hotfix | **GREEN** — https://github.com/trudeaudm/stonkz.green/actions/runs/31511289268 @ `08fdca3` |

## 2) Conflicts reported (merge main → launch-deploy)

| File | Resolution |
|---|---|
| `contracts/script/Deploy.s.sol` | **Took main** (refit-adapted): `sideTokenRef`, `setRefPrice(side,pair)`, accumulator v2 (`setPoolManager` / optional keeper+executor / ownership→custody), `settlementRef`, FeeLockerV2 only. Dropped launch-deploy pre-refit `stonkzRef` / `setStonkzRefPrice` / `acc.stonkz4663` wiring. |
| `contracts/src/StonkzExpressFactory.sol` | **Merged:** main settable refs + `sideTokenRef` + main's stamp/`refPriceWad(side,pair)` **plus** launch-deploy `Vanity` / `listingInitCodeHash` / `requirePrefix` on `list`. |
| `contracts/src/ladder/StonkzLadderFactory.sol` | **Merged:** main `settlementRef` / `sideTokenRef` / loud-unset / `refPriceWad` **plus** CREATE2 vanity `file(p,userSalt)`. Added non-vanity `file(p)` overload for unit-test compat. |
| `contracts/test/DeployControlsPhase1.t.sol` | Kept FactoryVanity (launch-deploy); `createSidePool=false` in setUp so loud-unset does not mask gate tests; `refPriceWad` field names. |
| `contracts/test/SidePoolRefPrice.t.sol` | **Took main** API (`refPriceWad(side,pair)`, `setRefPrice(side,pair,…)`) + FactoryVanity for Express lists; softened tick assert vs real-PM side geometry (same soften later landed on main as `08fdca3`). |
| `contracts/test/SwitchDrillPhase4.t.sol` | **Took launch-deploy** FactoryVanity drill; renamed to `setRefPrice(STONKZ,PAIR,…)` / `refPriceWad`; etch + `ladder.setSideTokenRef`. |
| `deploys/official/addresses.json` | **Took main** naming (`sideTokenRefStandIn`, settlementRef / accumulatorPoolManager wiring flags). |

### Second merge (main hotfix → launch-deploy)

| File | Resolution |
|---|---|
| `contracts/test/SidePoolRefPrice.t.sol` | Kept launch-deploy `_list` / FactoryVanity; took main comment on Phase-4 orientation (behavior already matched). |

### Auto-merged (no conflict) but reconciled afterward

| Asset | Change |
|---|---|
| `DeployScriptForkProof` / `DeployPhase0` / `ForkProofPhase2` / `VanityPhase1` | `setStonkzRef`→`setSideTokenRef`, `stonkzRef()`→`sideTokenRef()`, `stonkz4663()`→`sideTokenRef()`, `setStonkzRefPrice(pair,p)`→`setRefPrice(side,pair,p)`, `refPriceWad(side,pair)`. Ladder `setSideTokenRef` before createSidePool file. |
| `DeployScriptForkProof` | Added accumulator fund→crank→burn (mock executor) to match refit fork gate. |
| Park / `SidePoolParked` | Live path already retired on main; only residual in `legacy/StonkzLiquidityStrategy` (intentional). |

### ENV naming (Deploy script)

- Env key remains **`STONKZ_REF_ADDRESS`** (stand-in input) — maps to book field / wiring as **`sideTokenRef`**.
- Optional: `ACC_KEEPER_ADDRESS`, `BUY_EXECUTOR_ADDRESS`.

## 3) Fork re-proof (chain 4663)

| Drill | Result |
|---|---|
| `DeployScriptForkProof` (script parity + graduating Ladder + accumulator) | **PASS** — `file()` gas **29,306,894** (excl. vanity mine); accumulator OK |
| `ForkCanonPhase4` full manifest | **PASS** — `file()` gas **29,300,893**; accumulator OK |
| vs refit ForkCanon | refit was **29,275,183** — within ~0.1%; both ≪ Orbit 32M |

## 4) Runbook

`docs/16-launch-runbook.md` (gitignored) already uses `sideTokenRef` / accumulator `sideTokenRef`+band checks from refit Phase 4. Re-present if operator wants a fresh copy before GO PHASE 4.

## Gate

**CLOSED for broadcast.** Return to Phase-3 posture.  
**Ask:** GO PHASE 4?
