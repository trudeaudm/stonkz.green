# STOP — Factory switches Phase 1
**Branch:** `feat/factory-switches`  
**Scope:** deploysEnabled + allowlist (docs/03 switch 4) on Express AND Ladder.  
**Status:** Phase 1 complete. Pushed. **NO MERGE.**

## Rulings applied
- Phase 0 six YES + riders A/B/C (see `docs/stop-task-switches-plan.md`).
- Unlock recipient = creator, **stamped immutable at deploy** — confirmed in plan §3.4
  before Phase 1 code (withdraw wiring remains Phase 3).

## Delivered
| Artifact | Role |
|---|---|
| `contracts/src/DeployControls.sol` | Abstract: birth = on + deployer-only; events; `assertSoftLaunchGate` |
| `contracts/src/StonkzExpressFactory.sol` | CREATE2 `list(userSalt)`; salt = keccak256(deployer, userSalt); predict helper |
| `contracts/src/ladder/StonkzLadderFactory.sol` | Inherits DeployControls; `_requireDeployAllowed` on `file` |
| `contracts/script/Deploy.s.sol` | `DeploySoftLaunchGuard._assertSoftLaunchGate` for future deploy runs |
| `contracts/test/DeployControlsPhase1.t.sol` | 19 tests — birth, off, open, allowlisted, events, CREATE2, soft-launch assert |

## Semantics (locked in tests)
```
deploysEnabled == false     → DeploysOff (everyone)
deploysEnabled == true
  allowlistCount == 0       → OPEN (any caller)
  allowlistCount > 0        → only isDeployerAllowed
```
Owner is **not** implicitly allowlisted after self-revoke. Allowlist feature has no renounce path.

## Evidence
```
forge test --match-contract DeployControlsPhase1
19 passed
```
CREATE2: `predictListingAddress` == deployed address; salt binds deployer.

## Not in Phase 1 (by design)
- Side-pool / lock stamps (Phases 2–3)
- LadderSettlement → FeeLockerV2 (Phase 3; RIDER B vector hash gate)
- Vanity 0x4663 mining (RIDER C: path ready, no mining)

## Next
Phase 2 — createSidePool + sidePoolBps factory defaults/stamps.
