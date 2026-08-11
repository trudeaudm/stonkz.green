# STOP — SIDEPOOL-PRICE-LOCK

**Branch:** `feat/sidepool-price-lock`  
**Base:** `main` @ `08fdca3`  
**Broadcast:** none. Merge ruling awaits David. Last gate before GO PHASE 4.

## Why

TICK-ASSERT VERIFICATION: `08fdca3` soften was correct (no MIN_TICK bug), but left **no on-pool** assert that side-pool `slot0` matches ruled refprice. This branch closes that gap without weakening stamp arithmetic.

## What landed

| Asset | Change |
|---|---|
| `contracts/test/SidePoolPriceLock.t.sol` | **New** dual-backend suite (`Mock` + `Real` V4Adapter): Express ETH/USDG slot0+tick lock, Ladder vector-09 settle side lock, vacuity (1000× / 2× wrong expected → match fails) |
| `contracts/test/SidePoolRefPrice.t.sol` | **Beside** existing eth/usdg known-value checks: orientation-aware `getSlot0` + range tick asserts |

Lock semantics (mirrors production `_deploySidePool` / `_buildSidePool`):
- `priceInStonkz = start|print / ref`
- `tokIs0 = userToken < sideTokenRef`
- `initSqrt = getSqrtRatioAtTick(spotAligned(_sqrtPriceFromPriceWad(price, !tokIs0)))`
- `!tokIs0` ⇒ `sideTickLower == alignUp(MIN_TICK)`, `sideTickUpper == spotAligned`
- `tokIs0` ⇒ range above spot; slot0 tick == `spotAligned`

## Results

### SidePoolPriceLock — 8/8 PASS

| Backend | Express ETH | Express USDG | Ladder settle | Vacuity teeth |
|---|---|---|---|---|
| Mock | PASS | PASS | PASS | PASS (1000× + 2× fail match) |
| Real | PASS | PASS | PASS | PASS |

### tokIs0 / USDG orientation

| Backend | ETH salt1 | USDG salt2 | Flipped? |
|---|---|---|---|
| Mock | `false` | `false` | no |
| Real | `true` | `false` | **yes** |

Side pool key is `(sideTokenRef, userToken)` only — pair (ETH vs USDG) does not set `tokIs0`. Flip comes from CREATE2 userToken address vs sideToken. Real run covered **both** orientations (`true` and `false`).

### Regression suites

| Suite | Result |
|---|---|
| `SidePoolRefPrice` | 12/12 |
| `SidePoolEconomics` | 2/2 |
| `ListingAdapterPhase2` Mock+Real | 2/2 |
| `LadderPhase3` | 16/16 |
| `LadderVectorsReal` | 11/11 |
| Fork (`DeployScriptForkProof` / `ForkCanonPhase4`) | **Blocked this run** — RPC 403 (Cloudflare) to chain-4663 endpoint. Not a code fail. **Real-in-test PM** dual-backend locks above are the on-pool risk surface this gate required. |

RIDER B: untouched (no vector / mechanism math changes).

## Merge ruling

**Ask:** merge `feat/sidepool-price-lock` → `main` `--no-ff`?  
Then GO PHASE 4 remains a separate ruling (no broadcast from this branch).
