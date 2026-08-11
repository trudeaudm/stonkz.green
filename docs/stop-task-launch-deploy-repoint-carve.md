# STOP — launch-deploy re-point after CARVE-TREASURY-STAMP merge

**Branch:** `feat/launch-deploy` @ tip  
**Main merge:** `b789eee` (`Merge branch 'feat/carve-treasury-stamp'`)  
**Held posture:** Phase-3 gate — **no broadcast**. GO PHASE 4 awaits David.

## 1) Main merge

| Item | Value |
|---|---|
| Merge | `feat/carve-treasury-stamp` → `main` `--no-ff` |
| Merge hash | **`b789eee590314c2fc5ecd164575998ba0f0bf4df`** |
| Branch deleted | local + `origin` |
| CI | https://github.com/trudeaudm/stonkz.green/actions/runs/31523806058 |

## 2) Conflicts + reconciliations

| File | Resolution |
|---|---|
| `StonkzLadderFactory.sol` | **Merged:** launch-deploy CREATE2 vanity (`file(p,userSalt)` + plain `file(p)`) **+** main `carveTreasury` stamp in `_stampAuctionParams` (filer `p.treasury` overwritten). |
| `DeployControlsPhase1.t.sol` | Kept `createSidePool=false` for gate tests; added `setCarveTreasury(TREASURY)` (did **not** take main's sideTokenRef etch that would be unused with createSidePool=false). |
| `ForkCanonPhase4.t.sol` | Kept vanity mine + excl.-mine gas log; took main attacker-filer carve asserts (stamp + settle pay). |
| `Deploy.s.sol` | Clean from main: `CARVE_TREASURY_ADDRESS` env + wiring. |
| `DeployScriptForkProof` / Vanity / ForkProofPhase2 / DeployPhase0 | **Reconciled after:** `setCarveTreasury` before file (script-parity). |
| Runbook `docs/16` | Two-Safe table + cast checks for `carveTreasury()` vs `protocolTreasury()`. |

## 3) Fork re-proof

*(filled after run)*

## 4) Runbook GO-ready checklist

- [x] `TREASURY_ADDRESS` = fee Safe (hook flush)
- [x] `CARVE_TREASURY_ADDRESS` = protocol Safe (carve)
- [x] `STONKZ_REF_ADDRESS` / sideTokenRef stand-in
- [x] Hook mine step (`HOOK_CREATE2_SALT` + validate)
- [x] ETH refprice re-check (Express + Ladder)
- [x] Independent cast checklist (DeployControls, sideTokenRef, accumulator, ownership→custody, carveTreasury)
- [x] Ownership → custody

## Gate

**CLOSED for broadcast.**  
**Ask:** GO PHASE 4?
