# STOP — PREDEPLOY-REFIT Phase 3 (Ladder loud-unset + FeeLocker V1 → legacy)

**Branch:** `feat/predeploy-refit`  
**Ruling:** LADDER LOUD-UNSET — mirror Express 3a, guarded at filing. FeeLocker V1 → `contracts/legacy/` (Phase 0 ruling).  
**Held:** `feat/launch-deploy` @ `3fcdf74`

## 1. Filing guard (`StonkzLadderFactory`)

| Case | Behavior |
|---|---|
| `createSidePool=true` && `sideTokenRef==0` | Revert `SideTokenRefUnset` (same availability-guard shape as `vaultRef`) |
| `createSidePool=false` | Unaffected — genesis path files with ref unset |

Guard runs before `_requireRefPrice` so unset ref never reaches settlement via a new file.

## 2. Settlement backstop (`LadderSettlement`)

| Case | Behavior |
|---|---|
| `createSidePool=true` && `sideTokenRef==0` | Revert `SideTokenRefUnset` |
| Side pool build | Always `_buildSidePool` when `sideAmt>0` (no park branch) |
| `SidePoolParked` | **Deleted** (event + any parked accounting) |

Unreachable given filing guard except the mid-auction unset edge (owner clears settlement `sideTokenRef` after file).

### Mid-auction recovery state (documented in `LadderLoudUnset`)

Failed `settle` is atomic with the auction tx:

| Field | After backstop revert |
|---|---|
| `auction.settled` | **false** (rolled back) |
| Auction ETH balance | Unchanged — raised funds still escrowed |
| `graduated` / `done` | Still true (pre-settle clearing) |
| Recovery | Re-set `settlement.sideTokenRef` → `settle` succeeds |
| Unspent refunds | Still claimable via existing `claimRefund` paths (funds never left auction) |

## 3. FeeLocker V1 → legacy

| Item | Detail |
|---|---|
| Move | `contracts/src/FeeLocker.sol` → `contracts/legacy/FeeLocker.sol` |
| Production | **FeeLockerV2 only** (Express / LadderSettlement) |
| Tests retargeted | `FeechainE2E`, `SettlementConservation`, `PoolSeamAttacks`, `SidePoolEconomics`, `PoolKeyInvariants` |
| Strategy | `legacy/StonkzLiquidityStrategy` imports `./FeeLocker.sol` |
| Delete? | **No** — retained with README note |

## 4. Tests

`contracts/test/ladder/LadderLoudUnset.t.sol` — **4/4 PASS**

| Test | Result |
|---|---|
| `test_file_revertsWhenCreateSidePoolAndSideTokenUnset` | PASS |
| `test_file_succeedsWhenSideTokenSet` | PASS |
| `test_settle_backstop_unsetMidAuction_recoveryState` | PASS (recovery table above) |
| `test_genesis_createSidePoolFalse_filesAndSettlesWithRefUnset` | PASS |

Legacy FeeLocker importers + LoudUnset suite green in sampled run.

## Still open — Phase 4

- Full regression both backends (A1–A5, switches, vault e2e, hostile)
- `Deploy.s.sol` wiring adapt (settable refs / accumulator v2 / rename) from launch-deploy tip
- Runbook `docs/16` + R-L3CAP ledger note (feeReceiver=treasury at genesis; no special protocolFeeBps)
- FORK RE-PROOF chain 4663: deploy + graduating Ladder + accumulator fund→crank→burn; report `file()` gas
- `docs/19-refit-report.md` (gitignored) — STATE FOR MERGE RULING

**No merge / no broadcast.** `feat/launch-deploy` stays held.
