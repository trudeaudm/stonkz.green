# STOP — RIDER B gate (refined + accepted)
**Branch:** `feat/factory-switches`  
**Ruling:** 2026-08-10 — accept ABI-literal harness diffs under three conditions.  
**Status:** All three conditions **PASS**. Phase 4 proceeded.

## Amendment (all future chains)
Byte-identical applies to `contracts/test/vectors/**/*.json`. Harness `.t.sol` changes
are permitted only as ABI-literal hunks under per-hunk value review. Assertion /
tolerance-value hunks remain STOP. Recorded in `docs/15-switches-report.md`.

## Condition 1 — vector JSON byte-identical — PASS
All 10 `contracts/test/vectors/ladder/*.json` SAME vs `main` (`git hash-object`).  
Fixtures (`test/fixtures/ladder/*.json`) also SAME. `LadderVectorLoader.sol` SAME.

## Condition 2 — per-hunk value review — PASS
New field literals only (`createSidePool: true`, `stonkzRefPriceWad: 2.5e11` for ETH
`pairToken=address(0)`, SettleArgs lock fields `liquidityLocked: true` /
`unlockRecipient: CREATOR`, `sidePoolBps: 500` = fixtures / source `sidePoolPct=5`).  
Behavior-preserving vs vector generation. Zero assertion hunks.

LadderTolerance comment-only quote:
```diff
-    uint256 internal constant MONEY_ABS_FLOOR = 1e9; // 1e-9 WAD dollars
+    uint256 internal constant MONEY_ABS_FLOOR = 1e9; // 1e-9 pair-currency WAD
```
(constant value unchanged)

## Condition 3 — A1–A5 × 10 GREEN — PASS
LadderPhase1/2/3 vector suites: **29 passed, 0 failed** (incl. Phase3 `test_P3_A1A5_01`…`10`).

Prior gate STOP (hashes of `.t.sol` vs main) superseded by this ruling.
