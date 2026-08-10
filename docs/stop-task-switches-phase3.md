# STOP — Factory switches Phase 3
**Branch:** `feat/factory-switches`  
**Scope:** `liquidityLocked` stamp + unlock withdraw (docs/03 switch 1) + interlaced
side-pool `stonkzRefPriceWad` addendum (ruling B).  
**Status:** Phase 3 complete. Pushed. **NO MERGE.**

## Rulings applied
- Phase 0 YES + riders A/B/C.
- Unlock recipient = creator, stamped immutable.
- Ref-price ruling **B**: pair-wei per STONKZ, per-pair defaults/bounds, `RefPriceUnset`
  when createSidePool + unset (see `docs/stop-task-sidepool-refprice.md`).

## Delivered
| Artifact | Role |
|---|---|
| `DeployControls` | `defaultLiquidityLocked=true`; per-pair `stonkzRefPriceWad` + bounds |
| `FeeLockerV2` | Lock stamp registry + `requireCanWithdraw` / `markWithdrawn` |
| Express / Ladder factories | Stamp lock (+ ref) on list/file |
| `StonkzDirectListing` / `LadderSettlement` | Unlock withdraw gated on stamp; side init uses stamped ref |
| Ladder auction | Lock via `msg.sender.defaultLiquidityLocked()` (no Params field); vectors stay locked |
| `test/LockStampPhase3.t.sol` | Lock / withdraw / coexistence / fuzz 2048 |
| `test/SidePoolRefPrice.t.sol` | Ref-price arithmetic + stamp survival |

## Evidence
```
forge test --match-contract SidePoolRefPrice|LockStampPhase3|SidePoolSwitchesPhase2|
  DeployControlsPhase1|DirectListing|PoolKeyInvariants|VaultPhase1|CrossModelParity|LadderPhase3
→ all green
Known-value: ETH 4e15/2.5e11 → 1.6e22; USDG 4e15/1e15 → 4e18 STONKZ/token
```
C2 rug test unmodified on locked default; fuzz locked-never-withdraws 2048 runs.

## RIDER B
Vector assertion bodies unmodified. Params builders gained `stonkzRefPriceWad` literals
(compile ABI only). Suite green.

## Next
Phase 4 — full suite, switch-drill, coverage/gas, `docs/15-switches-report.md`,
docs/04 OPEN → RESOLVED (side-pool bounds + allowlist renounce).
