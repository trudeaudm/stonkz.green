# STOP — PREDEPLOY-REFIT Phase 1 (settable refs + rename + refprice rekey)

**Branch:** `feat/predeploy-refit`  
**Remote:** `https://github.com/trudeaudm/stonkz.green.git`  
**Phase 0 rulings:** all seven accepted (2026-08-11). Proceeded Phase 1 only.

## Shipped

| Change | Detail |
|---|---|
| `stonkzRef` → `sideTokenRef` | Express factory, DirectListing stamp, LadderSettlement setter, Ladder factory |
| `stonkzRefPriceWad` → `refPriceWad[sideToken][pairCurrency]` | DeployControls; `setRefPrice` / `clearRefPrice`; `RefPriceUnset(side, pair)` |
| Defaults | Seed on `setSideTokenRef`: `(side, ETH)=2.5e11`; Express also `(side, pairToken)=1e15` when pair≠0 |
| Express settable refs | `poolManager`, `feeLocker`, `hook`, `accumulator`, `ctoGovernor`, `pairToken`, `sideTokenRef` — each `*NotContract` + event |
| Ladder settable refs | `vaultRef` (existing), `settlementRef` (stamp when non-zero), `sideTokenRef` |
| Stamp isolation | New lists/files copy current refs; prior launches immutable — `SettableRefsPhase1` |
| Genesis-day | `setSideTokenRef` + prices → next Express pairs against new token; prior side pools unchanged |
| Vanity | Hook-only (unchanged). Listing/auction vanity not duplicated (ruling 4). |
| Park path | Untouched in Phase 1 (Phase 3 retires). |

## Tests

- `SidePoolRefPrice` — 12/12 (known-value arithmetic preserved)
- `SettableRefsPhase1` — 4/4 (prior-launch + genesis-day + NotContract)
- `DeployControlsPhase1` — 19/19 (CREATE2 predict fixed for new sideTokenRef)
- Ladder suites incl. A1–A5 Real — all green
- SwitchDrill / LockStamp / PoolKeyInvariants / Fee / CTO — green
- `vectors/*` — **byte-identical** (RIDER B)

## Not in this commit (later phases)

- Phase 2: BuybackAccumulator v2 (still mock 1:1 + park)
- Phase 3: park-path retirement + FeeLocker V1 → `contracts/legacy/`
- Phase 4: Deploy.s.sol wiring, runbook, fork re-proof, ledger R-L3CAP line

**Held:** `feat/launch-deploy` @ `3fcdf74`. No merge / no broadcast.

**Next:** Phase 2 accumulator rebuild (unless you want a ruling pause).
