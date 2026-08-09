# STOP / POST-VAULT-FIXUPS — feat/settle-permissionless
**Branch:** `feat/settle-permissionless`  
**Base:** `main` @ 642399a  
**Status:** Both items evidenced. **NO MERGE** — David ruling required.

---

## 1. Permissionless settle (Ladder)

### What changed
- `settle()` was already callable by anyone after `done` (no owner gate). NatSpec now
  states the ruled posture explicitly (same as vault execute / hook flush).
- **Wiring for factory path without a factory forwarder:** `Params.settlement` is
  stamped at auction construction. Filer deploys `LadderSettlement`, sets
  `p.settlement`, calls `factory.file` — settlement is live; anyone settles after the
  bell. No `factory.setAuctionSettlement`.
- `setSettlement` remains owner-only for direct-deploy tests (blocked once `settled`).

### E2E
`test_P1_factoryE2e_permissionlessSettle` (replaces the blocked-obstacle test):
factory.setVaultRef(real vault) → file with Params.settlement → bids → warp past
duration → finalize → `vm.prank(random)` settle → assert vault custody,
lockedBalance, three-leg raise split exact.

### Suites
- `forge test --match-path "test/vault/*"` — 27 passed
- `forge test --match-path "test/ladder/*"` — green after Params.settlement field added

---

## 2. CI flake pin — `invariant_exactWeiLedger`

### Seed (run 31319715297, attempt 1)
```
0xc7e344fca608811254e399a94cb2bc6e210c12bb6046e28ac776e407333478a9
```

### Pin command
```
forge test --match-test invariant_exactWeiLedger --fuzz-seed 0xc7e344fca608811254e399a94cb2bc6e210c12bb6046e28ac776e407333478a9 -vvv
```
**Reproduces FAIL** (not a non-deterministic harness flake).

### Shrunk sequence
1. `placeBid` ×2  
2. `poke` ×2  
3. `claim` — OutPrice path: refunds `budget - spent` only; `totalEscrowed -= unspent`;
   **spent remains inside `totalEscrowed`**  
4. `runAway` — sets `done=true`, `graduated=false`, `terminal=RanAway`  
   **does not adjust `totalEscrowed`**

### Wei / accounting mechanism (REAL BUG)
`escrowBook()` treats `done && !graduated` as failure accounting: for `_usdClaimed`
positions it **excludes** `spent` (assumes failure refunded full budget).

After OutPrice claim + later `runAway`:
- `totalEscrowed` still holds `spent` for those claimed positions  
- `escrowBook` drops that `spent` under failure rules  
→ `totalEscrowed > escrowBook` by Σ spent of OutPrice-claimed positions  

Pinned local fail shape: `totalEscrowed != escrowBook` (e.g. ~4.85e21 vs ~3.53e21).
Same sequence class as CI attempt 1 (`7578… != 6260…`).

### Verdict
**REAL BUG** in legacy `StonkzAuction.sol`: `runAway` flips the auction into
failure-shaped view state without reconciling `totalEscrowed` (or `escrowBook` does
not distinguish RanAway-after-OutPrice-claims from Failed-with-full-budget-refunds).

**Not fixed** — ruled: do not change legacy mechanism without a separate ruling.

### Is `StonkzAuction` legacy-dead or a live deployment target?
- **Not formally retired** (docs/11 M5 report: “Express `StonkzAuction` retirement”
  explicitly out of M5).
- **Rehearsal live targets** (docs/03): Express = `StonkzDirectListing`; Ladder =
  `StonkzLadderAuction` (joins rehearsal post-M5). Old waterfill `StonkzAuction` is
  **not** the new-launch path and is not named in rehearsal scope, but it remains
  in-repo and **CI-gated** (handler invariant job). Treat as **legacy mechanism code
  still load-bearing for CI / historical vectors**, not a rehearsal deploy target for
  new launches — unless David rules a retirement cut.

---

## Merge ask
Merge `feat/settle-permissionless` → `main` (`--no-ff`)?  
Item 2 is report-only (no legacy fix). Item 1 is the code change.
