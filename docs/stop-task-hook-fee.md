# STOP — HOOK FEE: pair-side, both directions (fix/hook-fee)

**Branch:** `fix/hook-fee` (from `deploy/mainnet-2026-08` @ `ecfa5ae`)  
**Authoritative input:** `C:\Users\david\stonkz-hook-recon.md`  
**Gate:** BROADCAST COMPLETE (FeeHook + CTOGovernor). **Safe pending:** `setHook` + `setGovernor`. Settlement deferred.

---

## Delivered

| Item | Status |
|---|---|
| Flags `BEFORE_SWAP \| AFTER_SWAP \| BEFORE_SWAP_RETURNS_DELTA \| AFTER_SWAP_RETURNS_DELTA` (= `0x0CC`) | done |
| `HookVanity` + `hook-vanity-mine.mjs` extended to `0x0CC` | done |
| Fee math: pair notional only; token-denominated fee unrepresentable | done |
| Exact-in BUY preserved (specified take in `beforeSwap`) | done |
| Exact-out BUY / exact-in SELL take in `afterSwap` from `abs(pairDelta)` | done |
| Exact-out SELL kept in `beforeSwap` (documented) | done |
| 75/25 split, flush, `canonManager` auth, bps==0 / unregistered soft no-ops, write-once stamp | preserved |
| NatSpec on every external/public; `forge doc` builds | done |
| `HookFeeDirections.t.sol` fork tests (a–e) | **5/5 PASS** |
| Deploy dry-run script `DeployHookFeeRewire.s.sol` | done (no broadcast) |

### Exact-out SELL placement (deliberate)

Kept in **`beforeSwap`**. The specified currency is already the pair, so `abs(amountSpecified)` is the pair notional (live-correct today). Moving it to `afterSwap` would not change the fee and would add a second take-site for a known amount. Unspecified-pair cases (exact-out BUY, exact-in SELL) are unified in `afterSwap`.

### INVARIANT (code + tests)

`beforeSwap` returns without taking unless `specified == pair`. `afterSwap` computes the fee solely from the pair currency's delta. A token-count fee cannot be represented.

---

## Mining

| Field | Value |
|---|---|
| Approach | Offline JS CREATE2 grind (`contracts/scripts/hook-vanity-mine.mjs --mode eoa`) against Foundry `CREATE2_FACTORY` `0x4e59…4956C` |
| Target | prefix `0x4663` + flags `0x0CC` (still ~2^30 expected) |
| `initCodeHash` | `0xcc840620ccd0089353f61e4e4098da6d366c63742dbf4590459459d773098235` |
| Ctor args baked in | `pm=0x97F2…AF6C`, `treasury=0xEF2F…7239`, `govPred=0xA81D…ffA9` (deployer nonce 57), `owner=0x8F50…d232` |
| **Salt** | `0x00000000000000000000000000000000000000000000000000000000c0215dfc` |
| **Predicted hook** | **`0x4663d17A2B8e2218A6bB84C2C098BB18777400cC`** |
| Attempts | 3,223,412,221 (~3.0× 2^30) |
| Wall clock | ~89 s (16 workers, ~30–48 kH/s local each) |

**Nonce sensitivity:** `initCodeHash` embeds the predicted `CTOGovernor` address. If deployer nonce ≠ 57 at broadcast, re-predict gov, re-hash, re-mine.

---

## Verify

| Check | Result |
|---|---|
| `forge build` (via-ir) | clean (exit 0) |
| EIP-170 runtime | FeeHook **11745**, LadderSettlement **18453**, CTOGovernor **7875** (max 24576) |
| `forge doc` | builds; FeeHook NatSpec includes both swap paths |
| `HookFeeDirections` (fork, real PM) | **5/5 PASS** |
| Worked numbers (bps=100, MOONER-like spot) | exact-in buy **1e13** wei; exact-out buy 1000 tok fee **≈2.17e11** (broken would be **10 ETH**); exact-in sell 10k tok fee **≈2.16e12** (broken would be **100 ETH**); adapter 100-tok sell fee **≈2.15e10** (not **1 ETH**) |
| Full `forge test -vv` | **277 passed / 3 failed / 280 total** |

### Pre-existing failures (unchanged by this fix)

Identical failures on this branch without the hook edit (hardcoded listing salts / loud sideTokenRef):

1. `SettableRefsPhase1.test_P1_express_refChange_neverAffectsPriorLaunch` — `VanityPrefixMismatch`
2. `SettableRefsPhase1.test_P1_genesisDay_sideTokenSwap_nextPairsNew_priorUnchanged` — `VanityPrefixMismatch`
3. `ForkProofPhase2.test_P2_fork_fullDrillManifest` — `SideTokenRefUnset`

Not regressions of `fix/hook-fee`.

---

## diff --stat vs `deploy/mainnet-2026-08`

```
 contracts/script/Deploy.s.sol              |   2 +-
 contracts/script/DeployHookFeeRewire.s.sol | new
 contracts/scripts/hook-vanity-mine.mjs     |  16 +-
 contracts/src/HookVanity.sol               |  38 +++-
 contracts/src/StonkzFeeHook.sol            | 338 ++++++++++++++++++++++++-----
 contracts/test/FeeHookPhase1.t.sol         |   6 +-
 contracts/test/HookFeeDirections.t.sol     | new
 docs/stop-task-hook-fee.md                 | this file
```

No listing template, factory bytecode, or adapter source changes.

---

## PHASE 1 DEPLOY DRY-RUN (no broadcast)

**Script:** `forge script script/DeployHookFeeRewire.s.sol:DeployHookFeeRewire --rpc-url $ROBINHOOD_RPC_URL --sender 0x8F50…d232`  
**Env:** `HOOK_CREATE2_SALT=0x…c0215dfc`

### Live reads (2026-08-19)

| Piece | Live |
|---|---|
| Express V4 factory | `0xEe2590c39E1485ed2F9cdaA684ab7B91d284E94a` (owner = custody) |
| Live hook (broken) | `0x4663c4c5Cb6F826d148cD38aDaF9157f483d0088` flags **136 = 0x088** |
| V4Adapter (Express V4) | `0x97F2b8679E70962A56A56338f54A2073a37aAF6C` |
| FeeLockerV2 (Express V4) | `0xf7e02D3F51Fe22Fa0428821552a087cFf07f0300` |
| Live LadderSettlement | `0x6b6E777d…a7E1` — **V3 adapter** `0xA4b4…469a` + **V3 locker** `0xe1e7…90E0` + old hook |
| Ladder factory | `0xdfF96ADb…2676` |
| Custody Safe | `0x9D116B03…5572` |
| Deployer | `0x8F5077eC…d232` nonce **57**, balance **≈0.000332 ETH** |
| Treasury (hook flush) | `0xEF2F5409…7239` |

### Predicted new addresses (nonce 57)

| Contract | Address |
|---|---|
| CTOGovernor (CREATE n) | `0xA81DcA58AA7d87E0EF0151b8a44acE1e152FffA9` |
| **StonkzFeeHook (CREATE2)** | **`0x4663d17A2B8e2218A6bB84C2C098BB18777400cC`** |
| LadderSettlement (CREATE n+3) | `0x19b11f85A193B14a8b4132D8A0B4510e32ce0Ddf` |

New settlement ctor: `(pm = V4Adapter 0x97F2…, hook = new, pairToken = 0)`.  
Wires `setSideTokenRef(0x5fc5…)` + `setFeeLocker(V4 FeeLocker 0xf7e0…)`, then ownership → custody.  
**Not** the live settlement's V3 adapter/locker pair.

### REUSED (do not redeploy)

V4Adapter, FeeLockerV2 (V4 gen), Express factory **bytecode** / listing template, PoolManager, Vault, BuybackAccumulator, UniversalRouter, Permit2.

### Deployer txs (after BROADCAST GO; not Safe)

A. `new CTOGovernor()`  
B. `new StonkzFeeHook{salt}(adapter, treasury, gov, deployer)`  
C. `gov.setRegistry(hook)`  
D. `new LadderSettlement(adapter, hook, 0)`  
E. `settlement.setSideTokenRef(stand-in)`  
F. `settlement.setFeeLocker(V4 FeeLocker)`  
G. `hook.transferOwnership(custody)`  
H. `settlement.transferOwnership(custody)`

### Safe payloads (custody 2-of-3; AFTER deployer txs)

| # | Call | to | calldata |
|---|---|---|---|
| 1 | `Express.setHook(newHook)` | `0xEe25…E94a` | `0x3dfd38730000…4663d17a2b8e2218a6bb84c2c098bb18777400cc` |
| 2 | `LadderFactory.setSettlementRef(newSettlement)` | `0xdfF9…2676` | `0xe7bd5c6f0000…19b11f85a193b14a8b4132d8a0b4510e32ce0ddf` |
| 3 | `Express.setGovernor(newGovernor)` | `0xEe25…E94a` | `0xc42cf5350000…a81dca58aa7d87e0ef0151b8a44ace1e152fffa9` |
| 4 | `V4Adapter.setAuthorized(newSettlement, true)` | `0x97F2…AF6C` | `0x711bf9b20000…19b11f85…0ddf…0001` |

All three Safe-owned targets (`express`, `ladder`, `adapter`) confirm `owner == custody`.

### Existing lists

`$MOONER` / SDONK / T / BONZI keep the **live** hook in `PoolKey` forever. This rewire is **new lists only**. Interim 0-fee unblock remains `bindCanonManager` on the live hook (not this script).

### Gas / balance note

Deployer balance ≈ 0.000332 ETH — **insufficient for mainnet broadcast** of three creates. Fund before GO. Dry-run did not measure gas; EIP-170 sizes are within limits.

---

## Recommendation only (no decision) — `hookFeeBps` write-once vs per-token setter

**Recommend keeping write-once** as the stronger trust property for launched tokens (docs/06: holder verifies the rate from the pool, never from current factory state). The break here was a denomination bug, not a missing dial; an owner-only `setHookFeeBps(token, bps)` bounded by `HOOK_FEE_BPS_MAX` would have let us zero fees per token without globally killing buy fees via `bindCanonManager`, but it would also let a compromised Safe change terms mid-life and weaken the immutable stamp story.

**Ops middle ground (if desired later, separate ruling):** keep stamped rates immutable; add only an owner-only **kill** (`setHookFeeBps(token, 0)` once) for emergency soft-disable without rebound. Not implemented here.

---

## Base-branch regression check (pre-broadcast)

Clean checkout of `deploy/mainnet-2026-08` @ `ecfa5ae`. Same 3 suite failures — **none pass on base and fail on fix** (not a regression from this change):

1. `SettableRefsPhase1.test_P1_express_refChange_neverAffectsPriorLaunch` — `VanityPrefixMismatch`
2. `SettableRefsPhase1.test_P1_genesisDay_sideTokenSwap_nextPairsNew_priorUnchanged` — `VanityPrefixMismatch`
3. `ForkProofPhase2.test_P2_fork_fullDrillManifest` — `SideTokenRefUnset`

(Predicted vanity addresses differ vs `fix/hook-fee` because hook bytecode changed listing initcode, but all three still fail.)

---

## BROADCAST (2026-08-20) — FeeHook + CTOGovernor only

**Scope (as ruled):** new FeeHook + `factory.setHook` + new CTOGovernor + `factory.setGovernor`.  
**Deferred:** LadderSettlement + `setSettlementRef` + adapter `setAuthorized` (ladder generation).

**Nonce drift:** dry-run mined for nonce **57**; at GO deployer was at **59** (CREATE slots 57–58 empty). Remined for nonce 59.

| Field | Value |
|---|---|
| Script | `DeployHookFeeExpress.s.sol` |
| Deployer nonce at send | **59** |
| `initCodeHash` | `0x97ecae4e8582bb6187fe24ea8736bfa85573dd7e5e989a7b27bd8c4ff6359fca` |
| Salt | `0x00000000000000000000000000000000000000000000000000000000c321d63d` |
| Attempts (remine) | 3,273,774,654 |
| **CTOGovernor** | **`0x355cCAeC798a935Cf94170cd49E9570A7cE23691`** |
| **StonkzFeeHook** | **`0x4663af1beE066E1699d093EFfb61Ab53c5a880Cc`** |
| `HOOK_FLAGS` on-chain | **204 = 0x0CC** |
| `hook.owner` | custody `0x9D116B03…5572` |
| `hook.canonManager` | PoolManager `0x8366a39C…0951` |
| `gov.registry` | new hook |
| Runtime sizes | FeeHook 11745 / Gov 7875 |

### Deployer txs (on-chain SUCCESS)

| Step | Tx |
|---|---|
| CREATE CTOGovernor | `0x888acc8b2811e43c3f9ab77f85526e115427d2bcda9c57d037ebc6eb008590a5` |
| CREATE2 StonkzFeeHook | `0x20e6c0de6b08f94ab93bb57bf5a86a8410d4d2b535c979a1811862370f2ce5de` |
| `gov.setRegistry(hook)` | `0x6b62ec82e1d25ee3a33425374b07cdc7b22aaa7de41af745a9ddd54da491b63b` |
| `hook.transferOwnership(custody)` | `0xff135e1f7a6d4eadffed036763b7ce66532e2acb4a25f57e86ddf60265074e5c` |

Post-broadcast deployer nonce **63**, balance ≈0.00396 ETH.

### Express factory (pre-Safe — still OLD)

| Ref | Live |
|---|---|
| `express.hook` | `0x4663c4c5…0088` (broken 0x088) |
| `express.ctoGovernor` | `0x39900709…49d0` |
| `express.owner` | custody Safe |

### Safe payloads (custody; execute to cut over new lists)

| # | Call | to | calldata |
|---|---|---|---|
| 1 | `Express.setHook(newHook)` | `0xEe2590c39E1485ed2F9cdaA684ab7B91d284E94a` | `0x3dfd38730000000000000000000000004663af1bee066e1699d093effb61ab53c5a880cc` |
| 2 | `Express.setGovernor(newGovernor)` | `0xEe2590c39E1485ed2F9cdaA684ab7B91d284E94a` | `0xc42cf535000000000000000000000000355ccaec798a935cf94170cd49e9570a7ce23691` |

**Not this phase:** `setSettlementRef`, `adapter.setAuthorized(settlement)`.

Existing lists keep the live broken hook in `PoolKey`. New lists after Safe cutover use `0x4663…80Cc`.

---

## STOP

Deployer broadcast done. **Await Safe execution** of `setHook` + `setGovernor`.  
Settlement rewire remains deferred to the ladder generation.
