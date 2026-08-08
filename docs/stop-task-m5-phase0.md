# STOP / PHASE 0 REPORT — STONKZ-M5-LADDER harness spine
**Branch:** `feat/m5-ladder`  
**Spec:** docs/09-ladder-spec.md (authoritative)  
**Status:** Phase 0 complete on this commit. NO merge — David ruling at end of M5.

## Disagreement check (prompt vs docs/09)
None found. Proceeded.
- `alpha = log2(1.1)` ≡ docs/09 `log2(1+β)` at β=10%
- `circFrac = 1 ALWAYS` until vault (docs/09 §1 + docs/03 2026-08-08)
- `MIN_ASK_BPS = 500` matches docs/09 §7
- Bids are NOT swaps (docs/06 + docs/03 2026-08-08)

## Fixed-point / units choice (Phase 0)
| Domain | Representation |
|---|---|
| Money (pair currency) | WAD = 1e18 wei |
| Prices (pair per token) | WAD (solady `FixedPointMathLib`; semantically ≡ UD60x18, no PRBMath dep) |
| bps-native rates | `uint16` bps with trailing unit comments |
| Token amounts | token wei (18-dec convention via same WAD scale from sim floats) |
| Period index | `elapsed * DESIGN_N / duration` — avoids truncating fractional rungPeriod (3.6s) to int seconds |

## Loader choice
**Pre-generated integerized JSON fixtures** at `contracts/test/fixtures/ladder/`, produced by checked-in `contracts/scripts/gen-ladder-fixtures.mjs` from authoritative `contracts/test/vectors/ladder/*.json`.

| Option | Decision |
|---|---|
| ffi | Rejected — non-deterministic CI surface |
| megabyte `.sol` codegen of 10×1000 path rows | Rejected — unwieldy |
| fixtures (chosen) | WAD/bps string JSON; `vm.readFile` + `stdJson`; CI-deterministic; regenerable |

Source vectors are **never modified** (test INPUTS). Fixture regen: `node scripts/gen-ladder-fixtures.mjs` from `contracts/`.

## Tolerance table (checked in as `test/ladder/LadderTolerance.sol`)
| Field class | Tolerance |
|---|---|
| Rung indices, booleans, failReason set | exact |
| Money legs (pair WAD) | 1e-9 relative, abs floor 1e9 wei |
| Token amounts | 1e-9 relative |
| Fractions (lpHealth) | 1e-9 relative |
| STOP if money rel widened beyond | 1e-6 |

## Canary evidence (vacuity guard)
| Run | Command | Result |
|---|---|---|
| GREEN | `forge test --match-test test_canary_raiseRatio_thresholdIdentity` | **PASS** (ratio 6000 bps → threshold $1500) |
| RED | `$env:CANARY_WRONG="true"; forge test --match-test test_canary_raiseRatio_thresholdIdentity` | **FAIL** `1750e18 != 1500e18` — harness compares |

In-suite companion `test_canary_wrongRatio_diverges` also pins that the wrong constant diverges.

## Suite (Phase 0 ladder path)
`forge test --match-path "test/ladder/*"`:
- LadderUnits: 10 passed
- LadderCanary: 2 passed (default env)
- LadderHarness: 4 passed (incl. A1–A5 fixture projection over all 10 vectors)

## Code landed
- `src/ladder/LadderConstants.sol` — parameter grid + periodIndex
- `src/ladder/LadderTypes.sol` — pinned schema structs
- `test/ladder/LadderTolerance.sol`, `LadderVectorLoader.sol`, `LadderAsserts.sol` (A1–A5)
- `test/ladder/LadderHarness.t.sol`, `LadderCanary.t.sol`, `LadderUnits.t.sol`
- `scripts/gen-ladder-fixtures.mjs` + `test/fixtures/ladder/*` (10 + manifest)
- `test/vectors/ladder/*` — David's 10 source vectors (tracked, unmodified)
- `foundry.toml` — read perm for `./test/fixtures`

## Open for later phases
- Phase 0 `replay()` projects fixture expected outputs; real `StonkzLadderAuction` lands Phase 1+
- A1 exact conservation is asserted on replay outputs; fixtures renormalize creator remainder so float dust does not false-fail the spine
- Full path load of all 10 vectors in one test is ~73s / high gas — acceptable for spine; Phase 1 may split at-bar cases

## Next
Phase 1 — rung math, time-derived periods, liveBudget, A5 green on vectors 02/04/05/07.
