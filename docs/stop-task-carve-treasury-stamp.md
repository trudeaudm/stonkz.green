# STOP — STONKZ-CARVE-TREASURY-STAMP

**Branch:** `feat/carve-treasury-stamp`  
**Base:** `main` @ `6099b8b`  
**Broadcast:** none. `feat/launch-deploy` held at tip until this merges, then re-points.

## Express

No raise carve / `toTreasury` on DirectListing. **No Express change.**

## Ladder

| Item | Detail |
|---|---|
| `carveTreasury` | Owner-settable; `CarveTreasuryChanged`; reject zero (`CarveTreasuryZero`); file requires set (`CarveTreasuryUnset`) |
| Stamp | `file()` → `p.treasury = carveTreasury` (filer ignored) |
| Guard | Zero only — Safe/EOA OK (payout address) |

## Deploy / docs

- `TREASURY_ADDRESS` = FeeHook fee Safe (flush)
- `CARVE_TREASURY_ADDRESS` = protocol Safe (carve)
- Runbook `docs/16` + ledger `docs/03` + report `docs/20-carve-stamp-report.md` (gitignored)

## Teeth

`CarveTreasuryStamp` 5/5: filer attacker → settle pays protocol Safe; stamp survives retarget.

## Re-prove

| Suite | Result |
|---|---|
| Reference engine | 19/19 |
| LadderPhase3 + LadderVectorsReal (A1–A5 ×10) | 16+11 PASS — RIDER B (direct auctions unchanged) |
| LadderPhase2, LoudUnset, DeployControls, SettableRefs, SidePool*, PriceLock Mock+Real, ListingAdapter, Vault, LockStamp, SwitchDrill | green |
| ForkCanonPhase4 | **PASS** — attacker `p.treasury` ignored; carve ETH → `carveTreasury`; `file()` gas **29,275,284** |

## Merge ruling

**Ask:** merge `feat/carve-treasury-stamp` → `main` `--no-ff`, then re-point `feat/launch-deploy`?  
GO PHASE 4 returns after that re-point (separate ask).
