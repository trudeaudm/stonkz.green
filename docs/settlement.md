# Settlement — Milestone 3 flow (spec §8)

> Source of truth for settlement is `docs/mechanism-spec.md` §8 (v1.1).
> This document is the human-review STOP surface: flow, modules, and the M3.5 gate.

## Precondition (satisfied)

| Item | Value |
|---|---|
| Base | `lazy-flip` merged to `main` |
| Merge commit | `d7ec5bc` ([PR #1](https://github.com/trudeaudm/stonkz.green/pull/1)) |
| PR CI (green) | https://github.com/trudeaudm/stonkz.green/actions/runs/30162808261 |
| Main push CI (green) | https://github.com/trudeaudm/stonkz.green/actions/runs/30162961406 |

## Flow

```mermaid
flowchart TD
  Filing["Filing<br/>lpShareBps default 10000<br/>creatorReserve + delivery INSTANT|VEST<br/>declaredUse · disposalMode"] --> Live["Auction live<br/>§2–§7 unchanged"]
  Live --> End{raised ≥ threshold?}
  End -->|no| Failed["Terminal: Failed<br/>full-budget refunds I8"]
  End -->|yes| Grad["Graduated"]
  Grad --> RunAway{"creator runAway<br/>pre-settle?"}
  RunAway -->|yes| RA["Terminal: RanAway<br/>bonded refunds"]
  RunAway -->|no| Settle["settle()"]
  Settle --> Split["F = lpShare × raised<br/>F_main = 95% · F<br/>F_carve = 5% · F flat"]
  Split --> Sync["sync spot → print<br/>bounded budget<br/>overrun → retryable"]
  Sync --> Main["Main pool<br/>price-setting: F_main + F_main/P<br/>INVARIANT tokens×P == usd<br/>surplus → disposal"]
  Sync --> Carve["BuybackAccumulator<br/>pair-currency carve<br/>NO market buy in settle"]
  Sync --> Side{"genesis spot<br/>readable?"}
  Side -->|yes| SidePool["Side pool<br/>5% LP tokens<br/>single-sided range<br/>bottom = 1 tick above grad/STONKZ<br/>top = 1000× · zero STONKZ exposure"]
  Side -->|no| Park["Park in Accumulator<br/>deploySidePool later"]
  Main --> FeeL["FeeLocker custody"]
  SidePool --> FeeL
  FeeL --> Term["Terminal: Settled"]
  Carve --> Crank["Keeper crank<br/>bounded STONKZ buys → BURN"]
  Park --> Deploy["deploySidePool<br/>permissionless"]
  Deploy --> SidePool
```

## Module map

| Contract | Role |
|---|---|
| `StonkzLiquidityStrategy` | `settle()`: sync, 95/5, price-setting, surplus, side pool, conservation getters |
| `BuybackAccumulator` | Carve + fees + pre-genesis parking; permissionless crank with hardcoded cap/cooldown; burns |
| `FeeLocker` | Immutable custody; main pair-fees → accumulator / user-token → burn; side compounds |
| `CreatorReserveLib` | INSTANT (10-min window) / VEST linear; declaredUse |
| `v4/*` + `MockPoolManager` | Minimal internal v4 surface; dual-backend for C1/C2 |

## Defaults & framing

- `lpShareBps` default **10000** → canonical auction:LP = **56.5 : 43.5** at κ̂ = 1.3
- Raise-side opt-down = `treasuryReserve`; token-side = `creatorReserve`
- Reserves are **tools, not fees**; no "compensation" / "creator cut" copy
- Flat 5% carve on **all** launches (cliff-gaming rationale — no tiers)

## Suites

| ID | Suite | Backend | Status |
|---|---|---|---|
| C1 | `PoolSeamAttacks` | mock (dual-backend harness) | **provisional** |
| C2 | `SidePoolEconomics` | mock (dual-backend harness) | **provisional** |
| C3 | `BuybackAccumulator` | — | gate |
| C4 | `TerminalState` | — | gate |
| C5 | `SettlementConservation` (100% LP) | — | gate |
| C6 | `Reserves` | — | gate |

Plus: reference 19/19, 200-vector fuzz seed 4663, §9 invariant campaign.

## M3.5 — REQUIRED before testnet

C1/C2 green on `MockPoolManager` does **not** prove tick math, sync-swap, or
front-created pool behavior against real Uniswap v4. M3.5 must:

1. Vendor `v4-core` (+ periphery as needed)
2. Re-run C1 and C2 **unmodified** against the real `PoolManager`
3. Land before any testnet deploy

## B6 vector report

**No section-A vectors regenerated.** All canonical / fuzz scenarios already set
`lpSharePct` / `lpShareBps` explicitly; only the engine/simulator *default* when
the param is omitted changed (80 → 100). Auction-engine vectors byte-unchanged.
