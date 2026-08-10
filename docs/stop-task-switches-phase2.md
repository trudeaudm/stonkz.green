# STOP — Factory switches Phase 2
**Branch:** `feat/factory-switches`  
**Scope:** createSidePool + sidePoolBps stamps (docs/03 switches 2–3).  
**Bounds (confirmed):** [0, 2000] bps, default 500.  
**Status:** Phase 2 complete. Pushed. **NO MERGE.**

## Delivered
| Artifact | Change |
|---|---|
| `DeployControls` | `defaultCreateSidePool=true`, `defaultSidePoolBps=500`, bounds max 2000, loud setters |
| `StonkzExpressFactory.list` | Always stamps current side defaults onto listing |
| `StonkzLadderFactory.file` | Always stamps current side defaults onto auction |
| `StonkzDirectListing` | Immutable `createSidePool` + `sidePoolBps`; false ⇒ all mass to main, no park |
| `StonkzLadderAuction` / `LadderSettlement` | `createSidePool` stamp; settle forces `sideAmt=0` when false |
| `LadderConstants.SIDE_POOL_BPS_MAX` | 2000 (aligned with DeployControls) |
| `test/SidePoolSwitchesPhase2.t.sol` | 12 tests |

## Evidence
```
forge test --match-contract SidePoolSwitchesPhase2|DeployControlsPhase1|DirectListing
→ all green (12 + 19 + 7)
```
Genesis `createSidePool=false`: sideTokens=0, listed=supply, park=0, `deploySidePool` reverts `SidePoolDisabled`.
Stamp survives default change on both factories.
Settlement absence path: createSidePool=false → sidePoolTokens=0, mainAsk=full unsold.

## Not in Phase 2
Lock stamp / FeeLocker withdraw (Phase 3). Vector suite untouched (RIDER B still applies at Phase 3).

## Next
Phase 3 — liquidityLocked stamp + unlock withdraw on Listing/Settlement.
