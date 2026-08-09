# STOP — circFrac: RESOLVED
**Branch:** `feat/m5-ladder`  
**Status:** Resolved by David design change 2026-08-08. See `docs/stop-task-m5-phase2.md`.

## Ruling (supersedes options 1/2/3)
- Holdback is VAULT-only; TAKE removed.
- `circFrac = 1 - holdbackPct` when holdbackPct > 0, else 1 — Mmax + gate.
- No vault ref ⇒ no holdback filing ⇒ circFrac = 1 by construction.
- Vector 08 passes unmodified; vector 09 TAKE void until replacement.
