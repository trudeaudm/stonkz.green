# STOP — LAUNCH-DEPLOY Phase 3 (runbook + SECURITY)

**Branch:** `feat/launch-deploy`  
**Remote:** `https://github.com/trudeaudm/stonkz.green.git`  
**After:** V4-CANON merged to main (`f5ad0a2`); launch-deploy unfrozen + re-pointed.

## Delivered

| Item | Status |
|---|---|
| Merge `feat/v4-canon` → `main` `--no-ff` | `f5ad0a2`; branch deleted local+remote |
| Unfreeze: merge main → `feat/launch-deploy` | conflicts **reported + resolved** (below) |
| Re-point `Deploy.s.sol` | RH PM pin + `V4Adapter`; **no MockPoolManager** in official book |
| Hook path | `HOOK_CREATE2_SALT` + `HookVanity` (0x4663+0x088) + `validateHookAddress` |
| Address book | PM / UR / Permit2 recorded; `V4Adapter` + mined hook |
| Fork re-proof | PASS — `file()` **29,305,993** vs Phase4 **29,274,312** (Δ +31,681 / ~0.11%) |
| `docs/16-launch-runbook.md` | local (gitignored); line items below |
| `SECURITY.md` + bounty tiers | repo root |
| CI on main after merge | failed 5× `poolHook==0`; fixed by stamping `hooks[id]=key.hooks` in `MockPoolManager.initialize` |

## Conflicts on unfreeze (not silent)

1. **`StonkzExpressFactory.list`** — launch-deploy: 0x4663 vanity predict/require; main/v4-canon: `{value: msg.value}` ETH buffer. **Resolution:** both.
2. **`StonkzToken`** — add/add; encoding/NatSpec only. **Resolution:** ASCII NatSpec, identical semantics.

## Runbook line items (David checklist)

- [ ] Safe custody address input + **test transaction** (round-trip on 4663)
- [ ] ETH refprice re-check vs spot before first side-pool launch
- [ ] Blockscout source verification (all address-book deploys)
- [ ] Hook mined-address verification (`0x4663` + `0x088` + `validateHookAddress`)

## Ruling requested

**Accept Phase 3 runbook + SECURITY.md?**

- **YES** → Phase 4 mainnet execution (explicit GO still required per send)
- **NO** → state gaps

Phases 4–5 remain gated on this review. No mainnet broadcast in this STOP.
