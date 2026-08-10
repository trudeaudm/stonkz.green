# STOP — LAUNCH-DEPLOY Phase 0 (deploy scripts)

**Branch:** `feat/launch-deploy`  
**Decision:** docs/03 `[D] 2026-08-10 ONE DEPLOY + SWITCHES COMPLETE`  
**Remote:** `https://github.com/trudeaudm/stonkz.green.git` (ABORT if stonkz-site)

## Delivered

| Artifact | Role |
|---|---|
| `contracts/src/StonkzToken.sol` | Protocol token: name STONKZ / ticker STONKZ4663; `100_000_000 ether`; no mint; custody-only genesis |
| `contracts/script/Deploy.s.sol` | Full-manifest deploy + wiring + soft-launch asserts + address-book write |
| `deploys/official/addresses.json` | Public address book (placeholder zeros until broadcast) |
| `contracts/test/DeployPhase0.t.sol` | In-process wiring / parked-supply / soft-launch mirror |
| `foundry.toml` | `fs_permissions` for `../deploys/official`; gas posture documented in script |

## Chain gate

- `4663` always allowed
- `31337` only if `FORK=true`
- else `WrongChain` — never a wrong live chain

## Wiring pass (asserted)

- `ladder.vaultRef` → vault
- `settlement.setStonkzRef(REAL token)` + `setFeeLocker`
- `gov.setRegistry(hook)` (one-shot, idempotent skip)
- Express `stonkzRef` = real token
- ETH ref `2.5e11` on both factories; USDG `1e15` when `USDG_ADDRESS` set
- Soft-launch closed + deployer-only on **both** DeployControls instances
- Full supply parked at `CUSTODY_ADDRESS`; zero approvals; no pools in script

## Env (keys never on disk / never in prompts)

`PRIVATE_KEY`, `CUSTODY_ADDRESS`, `TREASURY_ADDRESS`, optional `PAIR_TOKEN`, `USDG_ADDRESS`, `FORK`, `ADDRESS_BOOK_PATH`, optional `STONKZ_CREATE2_SALT`

Gas (100ms Orbit): `--gas-price 60000000 --priority-gas-price 0`

## NOTE — PoolManager (not a semantic invention; M3.5 status)

Manifest settles against **`MockPoolManager`** implementing our minimal `IPoolManager`.  
docs/01: **M3.5 real Uniswap v4 integration NOT STARTED**. Canonical RH PoolManager `0x8366a39C…` is **not** ABI-compatible with our surface. Address book records this under `config.poolManagerNote`. If David rules real-v4 is a launch gate, STOP and run M3.5 first.

## Idempotency

Skip-if-deployed per address-book entry when `code.length > 0`. Re-runs re-apply owner wiring (vaultRef / stonkzRef / feeLocker); `setRegistry` skipped if already set.

## Tests

`forge test --match-contract DeployPhase0` — green.

## Next

Phase 1 vanity (0x4663) + miner — separate commit/push.
