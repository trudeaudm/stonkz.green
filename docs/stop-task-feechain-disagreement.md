# STOP — FEECHAIN / M3.5 disagreement gate
**Branch:** `feat/m3-5-feechain`  
**Base:** `9419b8c` (main)  
**Status:** HALTED before PHASE 0 implementation. No Solidity edited.

Prompt rule: "where this prompt and docs/06 disagree, STOP and report the disagreement — do not pick one."

## Disagreement 1 (blocking) — hook fee factory bounds

| Source | Statement |
|---|---|
| Prompt PHASE 3 | Hard bounds on the factory default: **[0, 1000]** (0-10%). Default **1000** (= the 1% ruling). |
| `docs/06-fee-architecture.md` Adjustability | "Factory default bounded in the contract. **Bound is OPEN — see docs/04.**" |
| `docs/04` OPEN — M3.5 fee architecture | "Hook fee bounds: hard min/max on the factory default. Unbounded is an audit finding. Note the ceiling interacts with the published 40% cap promise. **UNRULED.**" |

Cannot stamp `hookFeeBps` factory defaults into code without picking a bound the prompt asserts and docs/06 explicitly leaves open. **Needs a David ruling** before PHASE 3 (and before any factory-default constant lands in earlier phases if they wire stamping).

## Disagreement 2 (docs/06 internal tension; resolved by [D] but reportable)

| Source | Statement |
|---|---|
| `docs/06` Design requirement 1 | "The token half of every fee is converted to ETH/USDG within the same swap." |
| `docs/06` Conversion ruling | Take fee on pair-currency side (input on buys, output on sells). "**No internal swap**… REPLACES [M4 convert-after-take]." |
| `docs/03` [D] 2026-08-03 M3.5 FEE ARCHITECTURE | Explicitly SUPERSEDES M4 convert-after-take / best-effort / crank. Pair-currency-side take. |

Reading: requirement 1 is satisfied *more completely* by never creating a token-denominated fee half (Conversion section + [D]). Prompt PHASE 0/3 follow the [D]/Conversion path. Flagging so David confirms requirement 1 is not a residual M4 obligation.

## Disagreement 3 (tokenomics vs M3.5; M3.5 wins if confirmed)

| Source | Statement |
|---|---|
| `docs/03` STONKZ TOKENOMICS Layer 1 | "swap fee: **1% on every pool, all pool types.**" |
| `docs/06` / M3.5 [D] Rates | Main: LP **0**, hook **100 bps**. Side: LP **30 bps**, no hook. |

M3.5 entry says it corrects the tokenomics session. Prompt follows docs/06. Confirm side pools are **30 bps LP**, not 1%.

## Also noted (not a prompt/docs/06 clash)

- Prompt PHASE 3: `protocolFeeBps` default **2500**, cap **4000** — aligns with docs/06 Layer 2 and prior mutable-fee drafts.
- Prompt: STONKZ pool = launched-pool config with both legs to protocol addresses — aligns with docs/06.
- Rename `stonkz4663` — TOKENOMICS says QUEUED, not in FEECHAIN scope. OK.

## PHASE 0 audit preview (read-only; nothing deleted)

`convertTokenToPair` callers found under `contracts/`:
- `contracts/src/v4/IPoolManager.sol:78-80` (declaration)
- `contracts/src/mock/MockPoolManager.sol:164` (impl)
- `contracts/src/StonkzFeeHook.sol:117,140` (+ NatSpec L22)
- `contracts/src/FeeLockerV2.sol:83` via `hook.crankConvert`
- Tests: `contracts/test/HookFees.t.sol` (multiple `crankConvert` lines)

No callers found outside that expected set in a first pass. Full IPoolManager-vs-canonical divergence list deferred until bounds ruling unblocks the chain (or David authorizes PHASE 0 to proceed while bounds stay OPEN).

## Ruling requested

1. Hook fee factory bounds: accept prompt **[0, 1000] default 1000**, or different numbers, or leave OPEN and defer stamping?
2. Confirm docs/06 Conversion/[D] supersedes Design requirement 1's convert-within-swap wording.
3. Confirm side pool LP fee **30 bps** (docs/06), not 1% (tokenomics Layer 1).

No merge. Awaiting ruling to continue FEECHAIN.
