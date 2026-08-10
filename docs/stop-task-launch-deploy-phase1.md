# STOP — LAUNCH-DEPLOY Phase 1 (vanity + miner)

**Branch:** `feat/launch-deploy`  
**Decision:** docs/03 `[D] 2026-08-03 VANITY PREFIX 0x4663` + ONE DEPLOY

## Delivered

| Artifact | Role |
|---|---|
| `contracts/src/Vanity.sol` | Prefix check + CREATE2 predict + mine (freemem-stable) |
| `contracts/src/StonkzExpressFactory.sol` | `listingInitCodeHash`; `Vanity.requirePrefix` before CREATE2 |
| `contracts/src/ladder/StonkzLadderFactory.sol` | CREATE2 `file(p, userSalt)`; same salt formula; vanity require |
| `contracts/scripts/vanity-mine.mjs` (+ `.ps1` wrapper) | Off-chain grind against **exact** init-code hash |
| `contracts/test/VanityPhase1.t.sol` | Mined salt → predicted; wrong salt reverts; two deployers diverge |
| `contracts/test/FactoryVanity.sol` / `VanityHelpers.sol` | Test mixin mines before list/file |

## Salt formula (unchanged)

`salt = keccak256(abi.encode(deployer, userSalt))` — both factories.

## Typed error

`Vanity.VanityPrefixMismatch(address predicted)` — top two bytes != `0x4663`.

## STONKZ token vanity — DECISION

**YES — mine 0x4663 for the protocol token** (script CREATE2 via `STONKZ_CREATE2_SALT` from `vanity-mine.mjs --mode eoa`).  
Brand: ticker lives at `0x4663…`; children of the factories match.

**OPEN (unchanged):** deeper `0x46634663` genesis-flex (32-bit / GPU-scale) — docs/03 candidate; not required for this chain.

## Tests

- `VanityPhase1` — green  
- `DeployControlsPhase1` — green (CREATE2 predict updated for vanity)  
- `SwitchDrillPhase4` / side-pool / lock suites — green after freemem-stable mine  

## Miner usage

```text
# After reading factory.listingInitCodeHash(p) / auctionInitCodeHash(p) on-chain:
node contracts/scripts/vanity-mine.mjs --factory 0xF --deployer 0xD --initCodeHash 0xH

# Protocol token (EOA CREATE2):
node contracts/scripts/vanity-mine.mjs --mode eoa --deployer 0xD --initCodeHash 0xH
```

## Next

Phase 2 — fork proof on chain 4663 (`FORK=true` / fork-url). **STOP for David review** after fork evidence.
