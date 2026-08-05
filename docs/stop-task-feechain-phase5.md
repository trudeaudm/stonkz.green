# FEECHAIN PHASE 5 REPORT — reconciliation + merge ruling
**Branch:** `feat/m3-5-feechain`  
**Status:** Phase 5 complete. Full private report: `docs/07-feechain-report.md` (gitignored).  
**Suite:** `forge test` **137 passed, 0 failed** (39 suites).

## Reconciliation greps

| Pattern | Live code hits | Classification |
|---|---|---|
| `convertTokenToPair` | comment-only (`IPoolManager`, `MockPoolManager`) | retirement comments — OK |
| `crankConvert` | none in `contracts/src` | OK (legacy public docs only) |
| `RECEIVER_BPS` / `TREASURY_BPS` | none | OK (Phase 3 STOP only) |
| `POOL_FEE` | none | OK (Phase 2 STOP only) |
| `best-effort` | 1 retirement comment in `IPoolManager.sol` | OK; mock live comment rephrased |
| `crankMainFees` | FeeLocker + FeeLockerV2 stubs (revert) + E2E expectRevert | retired path — OK |
| UNITS cross-label (`3000 (30 bps)` / pip-as-bps) | **0** after Phase 2 STOP gloss fix | OK — zero outside historical docs |

### UNITS check (mandatory addition)
Searched for glosses that attach bps labels to pip-scale integers (pattern that produced
`3000 (30 bps)`). Found one in `docs/stop-task-feechain-phase2.md` — **fixed this phase** to
`fee: 3000 pips = 0.3%`. Re-grep: **zero hits**. Legitimate `setDefaultProtocolFeeBps(3000)`
(3000 bps = 30% of hook fee) is not a cross-label.

## Coverage (fee-path match set, `--ir-minimum`)
| Contract | % Lines |
|---|---|
| StonkzFeeHook | 74.51% (76/102) |
| FeeLocker | 100% (21/21) |
| StonkzLiquidityStrategy | 75.64% (118/156) |
| MockPoolManager | 75.22% (85/113) |

Uncovered StonkzFeeHook lines: ownership, `setDefaultHookFeeBps`, `poolKeyOf`, failed-treasury
restore, ERC20 `_send`, `transferFeeReceiver`, `governorTransfer` — admin/CTO surfaces.

## Gas (mock, post-chain)
PROVISIONAL hook swap ~125k; `flush` ~100k; `registerPool` ~278k. Main LP fee 0 → no PM
LP accrual on main; hook accrue replaces convert+crank. Main-branch baseline not runnable
here (lib submodules missing in worktree).

## Docs updated (gitignored — not staged)
- `docs/06` → Status IMPLEMENTED; rates/units; launch-path gap CLOSED
- `docs/04` → fee-arch OPEN items marked RESOLVED / DEFERRED
- `docs/07-feechain-report.md` — full report + STATE FOR MERGE RULING

## Code tweak this phase
- `MockPoolManager`: rephrased `best-effort` ETH-forward comment (not M4 conversion).
- Phase 2 STOP: units gloss fix.

---

## STATE FOR MERGE RULING

Self-contained brief for David. Rule merge of `feat/m3-5-feechain` → `main` only after reading this section.

### Suite
- `forge test`: **137 passed, 0 failed** (39 suites) at Phase 5.
- Growth: 121 (P0) → 124 (P1) → 128 (P2) → 136 (P3) → 137 (P4/P5).

### Fee-path coverage
`forge coverage --ir-minimum --match-contract FeePhase3|FeeCanary|FeechainE2E|HookFees`
(via-ir minimum required — plain coverage hits stack-too-deep on LiquidityStrategy):

| Contract | Lines | Notes |
|---|---|---|
| `StonkzFeeHook.sol` | **74.51%** (76/102) | Core accrue/flush/register/custom covered |
| `FeeLocker.sol` | **100%** lines (92% stmts) | Main crank retire + side compound |
| `StonkzLiquidityStrategy.sol` | **75.64%** | Settle + register path via E2E |
| `MockPoolManager.sol` | **75.22%** | Hook fee=0 path |

**Uncovered on StonkzFeeHook (not fee-take critical path):**
`transferOwnership`, `setDefaultHookFeeBps`, `poolKeyOf` view, treasury-flush restore on failed send,
ERC20 `_send` branch, `transferFeeReceiver`, `governorTransfer`.

### Gas delta (mock)
Architectural change: main LP fee **0 pips** + hook take replaces M4 convert-after-take and
FeeLocker main→BuybackAccumulator. Apples-to-apples main-branch gas baseline unavailable
here (worktree lacked lib submodules). Intra-branch mock numbers:

| Path | Gas |
|---|---|
| PROVISIONAL hook swap (mock log) | ~125,491 |
| `MockPoolManager.swap` (gas-report avg, fee tests) | ~125,732 |
| `StonkzFeeHook.flush` | ~100,413 |
| `StonkzFeeHook.registerPool` | ~277,805 |
| Canary attached | ~127,700 |
| E2E full settle→swap→flush→side | ~1.34M (optimized build) |

### Canary evidence (both runs, re-verified Phase 5)
| Run | Command | Result |
|---|---|---|
| Attached | `forge test --match-test test_canary_fee0_hookAttached_protocolRevenueGtZero` | **PASS** |
| Detached | `$env:CANARY_DETACH='true';` same | **FAIL** `vacuity: fee take bypassed on fee=0 pool: 0 <= 0` |

### Side-pool hash baseline (UNMODIFIED across Phase 4–5)
| File | SHA256 |
|---|---|
| `contracts/test/SidePoolEconomics.t.sol` | `E2D995EDEB0489E4EBBBFD9346C54A09EEDB93667FC9F7AA5CC15E14E1F83C6A` |
| `contracts/test/BuybackAccumulator.t.sol` | `204F276204A16F5484A97EED0896A1539FDC310787D9DBBAB84FCC98BFC167DB` |

Side-pool tests GREEN unmodified: `test_C2_provisional_mockBackend`,
`test_C2_rangeTopIs1000xBottom`, `test_C3_preGenesisParkAndRelease`.

### [D] implemented this chain → code pointer

| [D] | Lives in code |
|---|---|
| Revenue at hook, pair currency, both launch paths | `StonkzFeeHook.afterSwap` / `_accrue`; register from DirectListing + LiquidityStrategy.settle |
| Main LP fee 0, hook 1% (100 bps) | `MAIN_LP_FEE=0`; `DEFAULT_HOOK_FEE_BPS=100`; mock quotes when fee=0 |
| Side LP 3000 pips = 0.3%, no hook, compound | `SIDE_LP_FEE=3000`; `_sidePoolKey` hooks=0; `FeeLocker.crankSideCompound` |
| Pair-currency-side take; no conversion | Phase 0 deletion; mock passes pair as `feeCurrency` |
| Per-pool stamp from mutable bounded factory default | `defaultHookFeeBps` + `hookFeeBps[token]`; bounds `[0,1000]` |
| Same pattern for protocolFeeBps (cap 4000) | `defaultProtocolFeeBps` / `setDefaultProtocolFeeBps` / stamp in `_register` |
| `_mainPoolKey` / `_sidePoolKey` split | Strategy + DirectListing |
| Auction wires hook; FeeLocker main→BuybackAccumulator retired | `settle`→`registerPool`; `FeeLocker.crankMainFees` reverts |
| Accrue-and-flush; trade-never-reverts | `flush`; try/catch in `afterSwap`; FeePhase3 hostile/fuzz |
| Custom-fee deploy owner-only | `registerPoolCustom` + `CustomFeeDeploy` |
| Gate 1: default 100 bps not 1000; side 0.3%; req#1 pair capture | Constants + docs/03 Gate 1 |
| Layer 3 target not commitment | No auto Layer-3 router; treasury holds flushed protocol share |

### Deferred OUT of this chain (docs/04 — still open)
| Item | Why out of FEECHAIN |
|---|---|
| **Emissions design** (fixed APR vs fixed budget) | Tokenomics; not fee-capture |
| **Fee accumulator ETH/USDG handling** (normalize vs per-asset) | Post-capture treasury ops; flush already per-pair |
| **Vesting terms** (team/community 5M) | Tokenomics / CreatorReserve |
| **Vampire-pool mitigation** (esp. STONKZ) | Explicitly OPEN in docs/06; no mechanism |
| **RH Chain `protocolFeeController()` check** | Mainnet exposure verification; needs live chain |

### Pins
- v4-core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`
- v4-periphery `545a5d2a87228167edde48f3b9eda122d1e3c4d6`

### Ask
Merge `feat/m3-5-feechain` → `main`? **Yes / No / Changes required.**  
Do not merge without an explicit ruling.
