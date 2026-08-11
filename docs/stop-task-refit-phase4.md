# STOP — PREDEPLOY-REFIT Phase 4 (reconciliation + merge ruling)

**Branch:** `feat/predeploy-refit`  
**Held:** `feat/launch-deploy` @ `3fcdf74` (re-point after merge)  
**Remote:** `https://github.com/trudeaudm/stonkz.green.git`  
**No merge / no broadcast** without David GO.

## Shipped this phase

| Item | Detail |
|---|---|
| `Deploy.s.sol` | Ported from launch-deploy + adapted: `sideTokenRef`, `setRefPrice(side,pair)`, Ladder `setSettlementRef`/`setSideTokenRef`, accumulator v2 (`setPoolManager`, optional keeper/executor, ownership→custody), FeeLockerV2 only |
| `deploys/official/addresses.json` | Placeholder book (no MockPM / no StonkzToken) |
| `foundry.toml` | `fs_permissions` for `../deploys/official` |
| Runbook `docs/16` | Accumulator `sideTokenRef` / owner / band checks; custody includes accumulator |
| Ledger `docs/03` | R-L3CAP note: default 25%; genesis feeReceiver=treasury |
| Report `docs/19-refit-report.md` | Gitignored STATE FOR MERGE RULING |
| Express side-pool real-PM | `_deploySidePool` mirrored to LadderSettlement orientation (Phase 3a set-ref path was broken on fork) |
| Fork | `ForkCanonPhase4` + accumulator fund→crank→burn drill |

## Regression (non-fork)

| Suite | Result |
|---|---|
| Broad `--no-match-contract ForkCanon` | **249 pass / 1 fail** → fixed `LadderPhase3.test_P3_minAskBps_reverts` (set `sideTokenRef` so loud-unset does not mask `MinAsk`) → **PASS** |
| A1–A5 Mock (`LadderPhase3`) + Real (`LadderVectorsReal`) | Green in broad run |
| Vault / switches / hostile / LoudUnset | Green |
| DirectListing + SidePoolSwitches after geometry port | **8+12 PASS** |

## Fork re-proof (chain 4663)

| Drill | Result |
|---|---|
| Express LOCK + UR-style swap (side pool set-ref) | PASS (after DirectListing geometry port) |
| Thin-book Ladder | PASS |
| Graduating Ladder + settle/vault | PASS |
| Switches | PASS |
| Hostile flush | PASS |
| Accumulator fund→crank→burn (mock executor, real PM spot) | PASS |
| `file()` gas | **29,275,183** vs Orbit 32M (~2.7M headroom); mock Phase2 ref 29,300,052 |

## Mid-auction loud-unset recovery (from Phase 3)

Settle crank reverts `SideTokenRefUnset`; `auction.settled` stays false; ETH remains escrowed; re-set ref → settle succeeds. Refund paths unchanged.

## R-L3CAP

No special `protocolFeeBps`. Default 25% of hook fee. Genesis `TREASURY_ADDRESS` = FeeHook protocolTreasury / feeReceiver.

## STATE FOR MERGE RULING

**Ask:** Merge `feat/predeploy-refit` → main (`--no-ff`)?  

After YES: re-point `feat/launch-deploy` onto new main; GO PHASE 4 (Safe drill + live broadcast) returns to David.  
**Do not** broadcast from this branch.

Vectors: RIDER B — untouched.
