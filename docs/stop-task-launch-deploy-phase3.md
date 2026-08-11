# STOP — LAUNCH-DEPLOY Phase 3 (stand-in re-proof / GENESIS VIA PLATFORM)

**Branch:** `feat/launch-deploy`  
**Remote:** `https://github.com/trudeaudm/stonkz.green.git`  
**Gate:** CLOSED — no mainnet until David **GO PHASE 4**.

## What changed (this STOP)

| Item | Status |
|---|---|
| Ledger `[D] 2026-08-10 GENESIS VIA PLATFORM` | local docs/03 |
| `Deploy.s.sol` — delete StonkzToken mint | done |
| `STONKZ_REF_ADDRESS` required + `StonkzRefInvalid` | done |
| Delete `StonkzNotParked` / custody mint checks | done |
| Address book — `StonkzRefStandIn`, no StonkzToken | done |
| Runbook — custody ownership-only; stand-in input; cast checks | docs/16 (local) |
| Fork re-proof graduating Ladder + side vs stand-in | see below |

## Fork re-proof

Run: `forge test --match-contract DeployScriptForkProof -vvv --gas-limit 20000000000`

| Metric | Value |
|---|---|
| `file()` gas (excl. vanity) | **29,306,017** |
| Phase4 ref | 29,274,312 (Δ +31,705 / ~0.11%) |
| Prior script-parity (mint era) | 29,305,993 (Δ +24 — noise) |
| Side pool | pairs vs stand-in; stand-in supply unchanged (dormant) |

## Manifest (final)

Factories + DeployControls, FeeHook (mined), V4Adapter, Settlement, Vault, refprices, soft-launch closed + deployer-only, ownership → Safe. **NO StonkzToken.**

## Ruling requested

**Accept revised script + runbook?** Gate stays CLOSED; **GO PHASE 4** is a separate message after Safe 2-of-3 drill + spot `ETH_REF_PRICE_WAD`.
