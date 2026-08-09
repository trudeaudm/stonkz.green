# STOP / VAULT REPORT — STONKZ-VAULT Management Vault
**Branch:** `feat/vault`  
**Spec:** docs/10-vault-spec.md  
**Status:** Phases 0–4 complete. Pushed. **NO MERGE** — request David ruling.

## Disagreement check
Prompt vs docs/10: none requiring STOP. See docs/12 for non-blocking impl notes.

## Canary (vacuity)
| Run | Result |
|---|---|
| GREEN (default) | PASS — 100 bps × 108 s/bps = 10_800 s |
| RED (`CANARY_WRONG=true`) | FAIL — 99900 != 10800 |

## Evidence summary
- Units identity locked; FIFO ruled example 1%+2%+1% → 3h/9h/12h
- Rate-stamp survives `setDirectRate`; cancel reflows successors
- Factory holdback filing reverts without vaultRef, succeeds after set (real vault)
- Vectors 08 + 09 settle into real vault; custody == lockedTokens; lockedBalance
  drops on queue file
- Path registry: mock path cooldown + pending-to-path locked; remove ≠ limbo
- Fuzz 2048: splitting invariance + reflow-on-cancel
- Owner cannot extract creator tokens (negative)
- Coverage StonkzVault lines ~89%; dead-name clean
- Gas depth-20: request ~180k / cancel-reflow ~46k / execute ~72k

## Full write-up
`docs/12-vault-report.md` (gitignored working doc; pattern verified).

## Pre-merge fix (2026-08-09 ruling)
- `setVaultRef` reverts `VaultRefNotContract` on EOA/empty; `address(0)` still clears.
- Settlement vault leg: no EOA transfer fallback — `VaultNotContract` if no code.
- Ladder EOA stubs rewritten as `test/ladder/MockVault.sol`.

## OBSTACLE — factory → settle e2e (not worked around)
`factory.file` sets `auction.owner = address(factory)`. `setSettlement` is
`onlyOwner` on the auction. Factory has no forwarding setter. Therefore
`factory.owner` (EOA), creator, and filer all revert `NotOwner` when calling
`setSettlement`. Production cannot wire settlement on a factory-filed auction
without a new factory method (or changing auction ownership at file).
Evidence: `test_P1_factoryE2e_blocked_auctionOwnerIsFactory`.

## Request
Merge ruling: `feat/vault` → `main`. Do not merge without David.
