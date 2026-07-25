# STOP — Milestone 3 Settlement (for human review)

**Branch:** `milestone-3`  
**Date:** 2026-07-25  
**Status:** **REVIEW ACCEPTED** (2026-07-25). §8 framing and M3.5∥M4 sequencing
confirmed. Findings below bind later gates — no M3 re-work.

## Precondition

| | |
|---|---|
| lazy-flip → main | [PR #1](https://github.com/trudeaudm/stonkz.green/pull/1) merged `d7ec5bc` |
| PR CI green | https://github.com/trudeaudm/stonkz.green/actions/runs/30162808261 |
| main push CI green | https://github.com/trudeaudm/stonkz.green/actions/runs/30162961406 |
| M3 → main | [PR #2](https://github.com/trudeaudm/stonkz.green/pull/2) merged `21eaf1b` |
| M3 CI green | https://github.com/trudeaudm/stonkz.green/actions/runs/30164150582 |

## Commits (milestone-3 tip → main)

| Hash | Summary |
|---|---|
| `b8bd05f` | docs(m3-a): settlement rewrite — reserves, 95/5 carve, side pool, defaults |
| `f7f5600` | chore(m3-b6): default lpSharePct=100 in engine + simulator UI |
| `2e7a3a5` | feat(m3): settlement contracts — strategy, accumulator, FeeLocker, terminal |
| `20cd345` | docs(m3): settlement.md flow + STOP |

Also on main via the precondition merge: `5003ec5` uint112/uint128 pack domain; `909f2af` I5 spent clamp.

## Local / remote gate

- Reference engine: **19/19**
- Foundry unit/vector: green
- 200-vector fuzz seed 4663: **PASS**
- Invariant campaign: **11/11**
- M3 C1–C6 suites: **20/20** (C1/C2 provisional; C3 partially provisional)

## B6 vector report

**None regenerated.** Scenarios already specified `lpSharePct` explicitly.

## Review findings (bind later gates — no re-work)

1. **Deployment ladder D2/D3** (promoted from former open items #3/#4) — testnet
   blocked until: factory wires token custody at construction; production
   filings REVERT on `liquidityStrategy == address(0)`. Logged in
   `docs/launch-plan.md` §8 + decisions log.
2. **M3.5 scope additions:** (a) named real-v4 price-setting ratio test;
   (b) full-range unreachable already exists as `test_C5_naiveFullRangeUnreachable`
   — re-run against real v4, do not duplicate; (c) C3 marked partially provisional
   in `docs/settlement.md` (conversion path needs real-pool re-validation).
3. **M4:** proceed when ready; M3.5 may run in parallel.

## Former open items (disposition)

| # | Item | Disposition |
|---|---|---|
| 1 | C1/C2 provisional | remains — M3.5 |
| 2 | C3 1:1 mock conversion | **partially provisional** — M3.5 conversion re-validation |
| 3 | `liquidityStrategy == address(0)` | **→ D3** deployment ladder |
| 4 | `userToken` at settle | **→ D2** deployment ladder |
