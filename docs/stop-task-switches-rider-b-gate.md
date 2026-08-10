# STOP — RIDER B gate (Phase 4 mandatory evidence #1)
**Branch:** `feat/factory-switches` @ `d5beb8b`  
**Gate:** Vector test file hashes must match `main`. **FAILED.**  
**Status:** STOP. No Phase 4 reconciliation / no merge until ruled.

## Hash comparison (`git hash-object` vs `git rev-parse main:path`)

| File | Branch | Main | |
|---|---|---|---|
| `LadderPhase1.t.sol` | `680833ea…` | `697adda2…` | **DIFF** |
| `LadderPhase2.t.sol` | `590c0acb…` | `5c370ebf…` | **DIFF** |
| `LadderPhase3.t.sol` | `618a7eeb…` | `3b21819c…` | **DIFF** |
| `LadderPhase4Base.sol` | `99eb098b…` | `462190f1…` | **DIFF** |
| `LadderVectorLoader.sol` | `7cf9f0fe…` | `7cf9f0fe…` | SAME |
| `LadderTolerance.sol` | (also differs — comment-only) | | **DIFF** |

## Diffs vs `main` (complete)

### LadderPhase1.t.sol (+2)
```diff
+                createSidePool: true,
+                stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
```
(inside `Params({...})` builder)

### LadderPhase2.t.sol (+4)
```diff
+            createSidePool: true,
+            stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
```
×2 Params sites (`_params` + one inline)

### LadderPhase3.t.sol (+10)
```diff
+            createSidePool: true,
+            stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
```
in Params builders, plus SettleArgs:
```diff
+                createSidePool: true,
+                sidePoolBps: 500,           # may already have existed in shape
+                stonkzRefPriceWad: 2.5e11,
+                liquidityLocked: true,
+                unlockRecipient: CREATOR,
```

### LadderPhase4Base.sol (+2)
```diff
+                createSidePool: true,
+                stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
```

### LadderTolerance.sol (+1/−1)
Comment unit wording only (`WAD dollars` → pair-wei clarification) — still a hash DIFF under the gate as written.

## Nature
All Phase1/2/4Base diffs are **Params/SettleArgs ABI field literals** required after
`createSidePool` (Phase 2) and `stonkzRefPriceWad` (ref-price addendum). No vector
assertion / load-bearing expect changes observed in the diff hunks.

## Gate reading (prompt)
> Any hash difference = list the diff and STOP. This gates the merge.

Hashes differ → **STOP**. Not proceeding to Phase 4 full reconciliation / merge-ruling
docs until you rule one of:

1. **Accept ABI-literal-only diffs** as RIDER B compliant (assertions unmodified; suite
   must still run green A1–A5×10) — then continue Phase 4 with this evidence attached; or
2. **Require byte-identical vector files** — then Params need a different stamping path
   that does not force test-file field lines (e.g. factory-only optional trailing args /
   defaults in a test helper outside the vector files), and we revert the test-file
   hunks.

## Not run under this STOP
- Full A1–A5×10 forge evidence (blocked by gate order: hash first)
- Lock read-once / refprice evidence items 2–3
- Phase 4 suite / docs/15

Awaiting ruling.
