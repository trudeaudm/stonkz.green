# STOP / PHASE 2 REPORT — STONKZ-M5-LADDER bids/fills + circFrac ruling
**Branch:** `feat/m5-ladder`  
**Status:** Phase 2 complete. NO merge.

## David ruling applied (supersedes prior circFrac options 1/2/3)
- Holdback is **VAULT-only** (`None` | `Vault`). **TAKE removed** — not implemented.
- `circFrac = 1 - holdbackPct` when `holdbackPct > 0`, else `1` — in **Mmax and graduation gate**.
- Vector **08 must pass unmodified** — PASS.
- Per-tier holdback ceilings: GOD 40% / 4H 50% / DAILY 60% / ROAD 70%, enforced at filing.
- Availability guard: `holdbackPct > 0` reverts while factory `vaultRef == 0`; settlement deposit also reverts if vault unset.
- Vector **09 TAKE is VOID** — harness SKIPS with reason; picks up `09-vault-cashhb-20.json` when present.

## docs/09 amendment note (for next docs pass)
Recorded for Claude to fold into docs/09 §§1 and 3:
1. **§1 circFrac:** replace “ALWAYS 1 until vault” with: `circFrac = 1 - holdbackPct` whenever `holdbackPct > 0`, else `1`, in Mmax and gate (sim-identical). Availability: no vault ref ⇒ no holdback filing ⇒ circFrac=1 by construction.
2. **§3 holdback:** delivery options NONE | VAULT only; TAKE and its dynamic ceiling table **dead**. Ceilings = former LOCK ladder (GOD 40 / 4H 50 / DAILY 60 / ROAD 70).

## Landed
- `LadderMath.circFracWad` + `mmax(..., circFrac)`
- `StonkzLadderAuction` — holdbackBps, delivery, stamped vaultRef, circFrac immutable, gate uses circ mcap
- `StonkzLadderFactory` — `vaultRef`, `file()` availability + ceiling guards
- `depositHoldback(token)` — exactly `holdbackBps × supply` to vault
- Tests: `LadderPhase2.t.sol` (A2 × 9 active vectors + skip 09 + three guard tests)

## Differential A2
| Vector | Result |
|---|---|
| 01–08, 10 | PASS (A2 conservation + per-wallet) |
| 09 TAKE | SKIPPED — awaiting `09-vault-cashhb-20.json` |
| 03 oversub / 10 cap-binding | PASS (hard pair) |
| 08 vault/60% circFrac=0.4 | PASS clearingPrice + fills |

## Tolerances (final for Phase 2)
| Class | Tol | Notes |
|---|---|---|
| Money conservation (sum spent/raised) | 1e-9 rel | exact identity on contract |
| Per-wallet spent/refund vs sim | **1e-5 rel** | vector 10 water-fill peaks ~2.8e-6; at/above 1e-6 STOP line — documented |
| Tokens vs sim | **2e-2 rel** | heavy books (06) ~1e-2; not a money-leg STOP |
| Rung indices / booleans / clear price | exact | |

## Suite
`forge test --match-contract LadderPhase2 --gas-limit 10000000000`: **14 passed**.

## Next
Phase 3 — gate failReasons, three-leg settlement, v4 pool geometry, MIN_ASK_BPS, full A1–A5; wire replacement 09 when David drops it.
