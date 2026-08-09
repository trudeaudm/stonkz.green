# STOP / PHASE 4 REPORT — STONKZ-M5-LADDER adversarial + invariants + gas
**Branch:** `feat/m5-ladder`  
**Status:** Phase 4 complete. NO merge.

## Addition (vault-holdback / circFrac fuzz)
Fuzz shapes sweep `holdbackPct ∈ [0, tier ceiling]` with cash holdback and strategies
(honest / decoy-heavy / split-bid / late-whale). Property under heaviest circFrac load:

> No combination graduates with `lpHealth < tierFloor`.

Rationale: circFrac exclusion shrinks the gate denominator and raises Mmax against the
same cash; vector 09 margin (0.3546 vs 0.35) is the tight band. Focused daily ceiling
sweep `[0..60%]` + 20% cash HB also green.

## Adversarial (docs/09 §9)
| Case | Result |
|---|---|
| Decoy high-max inflate liveBudget → priced out | PASS (refunds > 0; health if graduated) |
| Late whale in final periods | PASS |
| Split-bid vs single-bid **EXACT** equivalence (same address) | PASS (committed/spent/tokens/refund/raised/price) |
| Fuzz no-graduate-below-floor (96 runs; holdback×cashHB×strategy×tier) | PASS |
| Daily vault-holdback sweep + cash HB | PASS |

## Invariants
| Invariant | Result |
|---|---|
| Escrow conservation every state (bid / poke / clear / claim / settle) | PASS |
| Price monotone non-decreasing; ≤1 rung/period; on-grid; advance ≤ Mmax | PASS |
| Refund claimable exactly once (second claim reverts) | PASS |

## Gas snapshot @300 actives (user actions)
Setup `clearAll` ≈ 13.9B gas (harness; not the sanity bar). Soft ceilings held.

| Op | Gas | Soft ceiling |
|---|---|---|
| `placeBid` (300th unique) | **100,815** | 2,000,000 |
| `claimRefund` | **10,553** | 150,000 |
| `settle` | **798,919** | 5,000,000 |

`foundry.toml` `gas_limit` raised **5e9 → 2e10** so bare `forge test` covers Phase 4 gas setup.

## Suite
`forge test --match-contract "LadderPhase4(Adversarial|Invariants|Gas)" --gas-limit 20000000000`: **9 passed**.

## Landed
- `contracts/test/ladder/LadderPhase4Base.sol`
- `LadderPhase4Adversarial.t.sol` — decoy / late whale / split≡single / vault-holdback fuzz+sweep
- `LadderPhase4Invariants.t.sol` — escrow / monotone+Mmax / refund-once
- `LadderPhase4Gas.t.sol` — bid/claim/settle @300

## Note (view)
`fillOf` after a successful `claimRefund` still reports `committed - spent` (claimable
flag not consulted once `refundClaimable == 0`). Claim-once is enforced by storage +
revert; not a conservation bug. Optional cleanup later.

## Next
Phase 5 — dead-param grep, coverage, **STOP** to widen `.gitignore` to
`docs/[0-9][0-9]-*.md` before writing gitignored `docs/11-m5-report.md`, then
STATE FOR MERGE RULING. Do not merge.
