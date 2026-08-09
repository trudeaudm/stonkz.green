# STOP / PHASE 3 REPORT — STONKZ-M5-LADDER gate + settlement
**Branch:** `feat/m5-ladder`  
**Status:** Phase 3 complete. NO merge.

## Correction (vector 09)
| Action | Detail |
|---|---|
| Pickup filename | `09-vault-holdback-cashhb.json` (re-pointed harness + loader) |
| Deleted | `contracts/test/vectors/ladder/09-take-holdback-cashhb.json` + fixture twin — TAKE removed; skipped-forever shelf-noise |
| Expected checks | graduated ✓; lpHealth ≈ 0.3546 ≥ 0.35 ✓; locked 200,000,000 ✓; circMcap 49,600 vs FDV 62,000 ✓ |

## Vector 09 A1–A5 + dual extraction
Full A1–A5 green. Same settlement verifies:
- **Vault token holdback** = `holdbackBps × supply` (200M) deposited to vaultRef
- **Creator cash holdback** = `cashHoldbackBps × raised` (20%) paid to creator
- Carve to treasury (4%); three legs sum to raised **exactly**
- Hook `registerPool` as Express; main LP fee 0; cash/ask tick ranges ordered

## Landed
- `LadderSettlement.sol` — three-leg split, vault deposit, MIN_ASK_BPS, cash [floor,print] + tokens [print,inf), side pool 5% vs owner-settable STONKZ ref, `hook.registerPool`
- `StonkzLadderAuction.settle` + typed gate failReasons (`raise` / `lpHealth`) + `GateFailed` events
- Factory `defaultCarveBps` stamp + survive-default-change test
- `LadderPhase3.t.sol` — A1–A5 × 10, gate pair, carve stamp, MinAsk, hook register

## Differential A1–A5
| Vector | Result |
|---|---|
| 01–10 (09 = vault-holdback-cashhb) | **PASS** |
| 01 raise gate named | PASS |
| 08-shape health gate named (not raise) | PASS |
| Carve stamp survives default 400→700 | PASS |
| MIN_ASK_BPS revert | PASS |
| Hook register / fee 0 | PASS |

## Suite
`forge test --match-contract LadderPhase3 --gas-limit 10000000000`: **15 passed**.

## docs/09 note (carry)
§§1/3 amendments from Phase 2 still pending docs pass. Phase 3 implements §6 gate naming + §7 settlement as specified.

## Next
Phase 4 — adversarial + invariants + gas at 300 actives.
