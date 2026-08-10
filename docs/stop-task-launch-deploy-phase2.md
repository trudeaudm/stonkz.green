# STOP — LAUNCH-DEPLOY Phase 2 (fork proof)

**Branch:** `feat/launch-deploy` @ tip (push this commit)  
**Gate:** David reviews fork evidence before Phase 3 / any mainnet send.  
**RPC:** `https://rpc.mainnet.chain.robinhood.com` (public; override via `ROBINHOOD_RPC_URL`)  
**Harness:** `contracts/test/ForkProofPhase2.t.sol`  
**Run:** `forge test --match-contract ForkProofPhase2 -vvv --gas-limit 20000000000`

## Fork identity

| Field | Value |
|---|---|
| chainId | **4663** |
| mode | in-memory fork (no broadcast, no keys) |
| PoolManager | **MockPoolManager** (M3.5 real-v4 still NOT STARTED — same as Phase 0 note) |

## Drill matrix — expected vs observed

| Drill | Expected | Observed |
|---|---|---|
| Express LOCK ON list | vanity `0x4663…`, locked=true | OK (`0x4663dF28…` in earlier run; vanity assert) |
| Swaps both ways | mock swap completes | OK |
| Flush → pair currency | treasury receives protocol share | OK (treasury delta `7.5e15`) |
| Negative withdraw | `LiquidityIsLocked` | OK |
| Thin-book Ladder | raised << threshold → not graduated; soft-launch gate closed | OK (raised 5e18 / thresh 2.4e22; graduated false; assertSoftLaunchGate OK) |
| Gate named | soft-launch deployer-only | OK |
| **file() gas** | **< 32_000_000 Orbit** | **29,300,052** (excl. vanity mine) — **fits, ~2.7M headroom** |
| Small graduating Ladder | graduated true | OK (raised ~9.6e21 / thresh 6e21) |
| Vault deposit | holdback to vault | OK (1e23 wei) |
| Queue request/cancel/reflow/execute | direct-release path | OK (id 1; cancel; re-request; execute) |
| Switch off/on | DeploysOff then restore | OK |
| Allowlist | stranger blocked; friend lists | OK |
| Side-pool toggle + genesis | createSidePool=false → no side | OK |
| Lock coexistence | locked vs unlocked stamps | OK |
| Custom-fee 300 bps | hookFeeBps=300 | OK |
| Carve stamp | survives default change | OK |
| Refprice stamp | 5e11 stamped on later list | OK |
| Hostile receiver | flush non-reverting; swap accrues | OK |

## THE product number

**`file()` gas on fork = 29,300,052** vs Orbit block gas limit **32,000,000**.  
Fits today. If filing grows past ~32M, split file+initialize (docs/03 NOTE).

## Divergences / notes for David

1. **MockPoolManager on fork** — proves our stack under RH chain-id / gas schedule, not canonical Uniswap v4 PM ABI. Real-v4 = M3.5.
2. Graduating drill needed **12 bidders @ 10% wallet cap** to clear raise bar (1% default caps max raise below threshold) — mechanism behavior, not a bug.
3. Thin-book gate named as **soft-launch DeployControls** (closed/deployer-only); auction fail reason is raise (logged graduated=false).

## Ruling requested

- **Accept Phase 2 fork evidence?** → unblocks Phase 3 (runbook + SECURITY.md).  
- **Do not** mainnet-send until Phase 3 runbook gate + explicit David GO.

No merge. Gate stays CLOSED.
