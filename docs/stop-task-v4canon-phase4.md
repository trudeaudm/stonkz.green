# STOP — V4-CANON Phase 4 (fork gate vs RH singleton PM)

**Branch:** `feat/v4-canon`  
**Gate:** David reviews fork evidence before next phase / any mainnet send.  
**RPC:** `https://rpc.mainnet.chain.robinhood.com` (override via `ROBINHOOD_RPC_URL`)  
**Harness:** `contracts/test/ForkCanonPhase4.t.sol`  
**Run:** `forge test --match-contract ForkCanonPhase4 -vvv --gas-limit 20000000000`  
**Result:** **2/2 PASS** (full drill + protocolFeeController probe)

## Fork identity

| Field | Value |
|---|---|
| chainId | **4663** |
| mode | in-memory fork (no broadcast, no keys) |
| PoolManager | **singleton** `0x8366a39CC670B4001A1121B8F6A443A643e40951` via **V4Adapter** (NOT MockPoolManager) |
| Universal Router pin | `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` (code present) |
| Permit2 pin | `0x000000000022D473030F116dDEE9F6B43aC78BA3` (canonical; code present) |
| Hook | CREATE2 flag-valid `0x…088` (`HookVanity.HOOK_FLAGS`); `bindCanonManager(PM)`; binds via `PoolKey.hooks` only |

## Drill matrix — expected vs observed

| Drill | Expected | Observed |
|---|---|---|
| Express LOCK ON list | locked=true; hook flags; `PoolKey.hooks` | OK |
| UR-style swap (adapter unlock) | buy via V4Adapter vs singleton | OK (fee accrued 5e14; treasury flush delta 1.25e14) |
| UR-style sell | optional | **Skipped** — token exact-in takes pair fee as 1% of token notional (`OutOfFunds`); buy path is the Express production flow. Noted below. |
| Flush → treasury | protocol share moves | OK |
| Negative withdraw | `LiquidityIsLocked` | OK |
| Thin-book Ladder | not graduated; soft-launch gate | OK (raised 5e18 / thresh 2.4e22; graduated false) |
| Gate named | soft-launch deployer-only | OK |
| **file() gas** | **< 32_000_000 Orbit** | **29,274,312** — fits; ~2.73M headroom |
| file() vs mock Phase2 | compare 29.3M | **29,274,312** vs **29,300,052** mock (no vanity CREATE2 on this branch) |
| Small graduating Ladder | graduated + **settle on real PM** | OK (raised ~9.6e21 / thresh 6e21) |
| Vault via settle | holdback deposit | OK (1e23 wei) |
| Queue request/cancel/reflow/execute | direct-release path | OK |
| Switch off/on | DeploysOff then restore | OK |
| Allowlist | stranger blocked; friend lists | OK |
| Side-pool toggle + genesis | createSidePool=false → no side | OK |
| Lock coexistence | locked vs unlocked stamps | OK |
| Custom-fee 300 bps | hookFeeBps=300 | OK |
| Carve stamp | survives default change | OK |
| Refprice stamp | 5e11 stamped on later list | OK |
| Hostile receiver | flush non-reverting | OK |

## THE product number

**`file()` gas on fork (real PM path) = 29,274,312**  
vs mock Phase2 figure **29,300,052** vs Orbit block gas limit **32,000,000**.

Fits today (~2.73M headroom). Vanity CREATE2 on launch-deploy added negligible overhead vs plain `file(p)` here. If filing grows past ~32M, split file+initialize (docs/03 NOTE).

## protocolFeeController probe

| Field | Value |
|---|---|
| `protocolFeeController()` | `0x6d0009504D129CF5002Dba61D9Ae8575AA79314c` (**V4FeeAdapter**, live) |
| `policy()` | `0x6ee984309ba26c224f12Bb85D6F7f3C019483DFc` (**V4FeePolicy**) |
| `TOKEN_JAR()` | `0x2aC03e14Cfe755426DaAEe0a4994184Ce81482F8` |
| `feeSetter()` / `owner()` | `0x2BAD8182C09F50c8318d769245beA52C32Be46CD` |
| Main pool `getFee` (LP fee 0 + hook flags) | **0** — no Uniswap protocol take (docs/06 LP-fee-0 architecture holds) |
| Side pool `getFee` (LP fee 3000 pips, no hook) | packed **2048500** = **500 \| 500** pips = **5 bp each direction** |

**Side-pool exposure if/when fees are activated on a pool: ≤5 bp** (matches docs/06: 30 bp LP → 5 bp protocol). Main pools stay at 0 by architecture. Controller is **already set** on RH (not address(0)); fees resolve via V4FeePolicy native-math schedule.

## Divergences / notes for David

1. **Real singleton PM** — this is the Phase 4 gate; MockPoolManager is not on the production path under test.
2. **Express stonkzRef=0 (park)** — DirectListing side-pool geometry still demands STONKZ under some real-PM orientations (`InsufficientAllowance` on STONKZ). LadderSettlement Phase 3 geometry was used for graduating settle (side pool built OK). Express side deploy vs real PM remains a follow-up (not blocking fork gate of adapter+hook+settle).
3. **UR-style swap** — exercised via `V4Adapter.swap` (same unlock/settle netting UR uses). UR + Permit2 pins verified with code on fork. Sell leg skipped (hook fee denom on token exact-in); buy+flush green.
4. **Drill cash seed** — Express ask is one-sided above spot; zeroForOne buys need cash below. Test seeded a thin ETH bid below live tick (test-only) so the unlock path could run.
5. **No listing/auction vanity** — factories on `feat/v4-canon` do not enforce `0x4663` prefix; plain salts. Hook mines **flags only** (`0x088`); production `0x4663…088` remains offline miner job.
6. **Ported** `contracts/src/StonkzToken.sol` (minimal) for settlement side-ref / accumulator wiring.

## Artifacts

- `contracts/test/ForkCanonPhase4.t.sol`
- `contracts/src/StonkzToken.sol` (port from launch-deploy; read-only source)
- This STOP

## Ruling requested

- **Accept Phase 4 fork evidence?** → unblocks next V4-CANON step / runbook.
- **Do not** mainnet-send until explicit David GO.
- Optional follow-ups (non-blocking for this STOP): Express side-pool real-PM geometry; pair-out fee denom on sells.

No merge. Gate stays CLOSED pending ruling.
