# STOP — Milestone 3 Settlement (for human review)

**Branch:** `milestone-3`  
**Date:** 2026-07-25  
**Protocol:** push-before-ruling. This STOP is incomplete until `git push` of
these commits has succeeded and remote CI on the milestone-3 → main PR is green.

## Precondition

| | |
|---|---|
| lazy-flip → main | [PR #1](https://github.com/trudeaudm/stonkz.green/pull/1) merged `d7ec5bc` |
| PR CI green | https://github.com/trudeaudm/stonkz.green/actions/runs/30162808261 |
| main push CI green | https://github.com/trudeaudm/stonkz.green/actions/runs/30162961406 |

## Commits (milestone-3 tip → main)

| Hash | Summary |
|---|---|
| `b8bd05f` | docs(m3-a): settlement rewrite — reserves, 95/5 carve, side pool, defaults |
| `f7f5600` | chore(m3-b6): default lpSharePct=100 in engine + simulator UI |
| `2e7a3a5` | feat(m3): settlement contracts — strategy, accumulator, FeeLocker, terminal |
| *(this)* | docs(m3): settlement.md flow + STOP |

Also on main via the precondition merge (not M3, listed for the pack-domain repair
that unblocked CI): `5003ec5` uint112/uint128 pack domain; `909f2af` I5 spent clamp.

## Local gate (before push)

- Reference engine: **19/19**
- Foundry unit/vector (CI-equivalent filter): **75 passed, 0 failed**
- 200-vector fuzz seed 4663: **PASS**
- Invariant campaign: **11/11**
- M3 C1–C6 suites: **20/20** (C1/C2 provisional on mock)

## B6 vector report

**None regenerated.** Scenarios already specified `lpSharePct` explicitly.

## Open items / M3.5

1. **C1/C2 provisional** on `MockPoolManager` — real v4 re-run required before testnet (spec §10.1).
2. Buyback crank uses 1:1 mock conversion until genesis pool exists.
3. `liquidityStrategy: address(0)` keeps legacy accounting-only settle for existing auction tests; production filings must point at a deployed strategy.
4. Auction→strategy still passes `userToken` at settle time; factory/manager mint wiring is a follow-on.

## Ask of the human

1. Confirm the §8 framing (100% LP default, flat 5% carve, reserve renames, no settle-time market buys).
2. Confirm M3.5 sequencing (merge M3 with provisional C1/C2; block testnet on real-v4 C1/C2).
3. On remote CI green for the milestone-3 PR: approve merge.
