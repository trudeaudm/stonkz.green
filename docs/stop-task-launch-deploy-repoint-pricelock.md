# STOP — launch-deploy re-point after SIDEPOOL-PRICE-LOCK merge

**Branch:** `feat/launch-deploy` @ tip (post-merge)  
**Main merge:** `6099b8b` (`Merge branch 'feat/sidepool-price-lock'`)  
**Held posture:** Phase-3 gate — **no broadcast**. GO PHASE 4 awaits David.

## 1) Main merge

| Item | Value |
|---|---|
| Merge | `feat/sidepool-price-lock` → `main` `--no-ff` |
| Merge hash | **`6099b8b1a84c07cb526eda583bd54db5e01f7368`** |
| Branch deleted | `feat/sidepool-price-lock` local + `origin` |
| CI | https://github.com/trudeaudm/stonkz.green/actions/runs/31516032151 |

## 2) Conflicts + reconciliations (merge main → launch-deploy)

| File | Resolution |
|---|---|
| `contracts/test/SidePoolRefPrice.t.sol` | **Conflict.** Kept launch-deploy `FactoryVanity` + `_list(...)`; took main `using PoolIdLibrary` + `_assertSidePoolOnPoolPrice` on-pool slot0/tick asserts beside stamp arithmetic. **12/12 PASS** after resolve. |
| `contracts/test/SidePoolPriceLock.t.sol` | **Clean add from main**, then **reconciled:** Express `list` on this branch enforces `Vanity.requirePrefix` → wired `VanityHelpers.mineExpress` + `FactoryVanity` mixin + `vm.deal` for ETH buffer. Fixed salts (bytes32(1/2/7)) removed in favor of mined salts. Ladder settle path unchanged (no vanity). **8/8 PASS** Mock+Real after reconcile. |
| `docs/stop-task-sidepool-price-lock.md` | Clean add from main (no conflict). |

No Deploy.s.sol / factory / accumulator conflicts (price-lock was test-only on main).

## 3) Fork re-proof (chain 4663)

*(filled after RPC retry)*

### Non-fork evidence covering deploy path (if RPC still 403)

- `SidePoolPriceLockReal` — Express + Ladder side init on Real-in-test PM (slot0 lock)
- Prior launch-deploy fork results @ `c591717` era (`DeployScriptForkProof` file() gas ~29.3M) remain the last successful chain-4663 script-parity proof if RPC blocked

## Gate

**CLOSED for broadcast.** Return to Phase-3 posture.  
**Ask:** GO PHASE 4?
