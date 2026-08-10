# STOP — Side-pool init price / `stonkzRefPriceWad` denomination
**Branch:** `feat/factory-switches`  
**Scope:** Phase-3 ADDENDUM — stamped `stonkzRefPriceWad` for Express + Ladder side-pool init.  
**Status:** RESOLVED — ruling **B** (refined). Implemented with Phase 3 lock stamp.

---

## Ruling (David)

**B — ref is PAIR-PER-STONKZ**, same WAD unit as `startPriceWad` / `printPrice`.
No USD in the conversion; one multiplication, zero unit crossings.

| Pair key | Launch default | Bounds | Unit |
|---|---|---|---|
| ETH `address(0)` | `2.5e11` | `[1e8, 1e17]` | pair-wei per STONKZ token, WAD |
| USDG (non-zero) | `1e15` | `[1e12, 1e21]` | pair-wei per STONKZ token, WAD |

- Per-pair mapping on `DeployControls`; owner-settable; `RefPriceChanged`; stamped per deploy.
- `createSidePool=true` + unset pair ⇒ `RefPriceUnset` (never a fallback constant).
- ETH figure is a **deploy-runbook** line (re-check vs spot); see `Deploy.s.sol` + docs/04.
- docs/04 TWAP queue stands (post-genesis).

---

## Delivered

| Artifact | Change |
|---|---|
| `DeployControls` | Per-pair `stonkzRefPriceWad` / `Configured`; ETH birth default; USDG seed helper; bounds; clear; events |
| `StonkzExpressFactory` | Seeds USDG default for non-ETH `pairToken`; stamps ref on `list` |
| `StonkzLadderFactory` | Stamps ref on `file` from `p.pairToken` |
| `StonkzDirectListing` | Immutable stamp; `priceInStonkz = startPriceWad * WAD / ref` |
| `StonkzLadderAuction` / `LadderSettlement` | Params/SettleArgs stamp; convert `printP` before sqrt |
| Phase 3 lock | Folded in (liquidityLocked + FeeLocker withdraw) |
| Unit comments | "WAD dollars" → "pair currency (WAD)" on ladder money fields |
| Tests | `SidePoolRefPrice.t.sol` + `LockStampPhase3.t.sol` |

## Conversion (both paths)
```
priceInStonkz = pairPerTokenWad * WAD / stonkzRefPriceWad
// both numerator price and ref: pair-wei per token, WAD
```
