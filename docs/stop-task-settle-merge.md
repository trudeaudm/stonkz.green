# STOP / SETTLE-MERGE + LEGACY RETIREMENT
**Merge hash:** `87294f3f82bd3cb8e95089fafd466029aa3ab299`  
**CI (merge):** https://github.com/trudeaudm/stonkz.green/actions/runs/31325174688 — **green**  
**Branch deleted:** `feat/settle-permissionless` (local + remote)

## Pre-merge check — settlement rewire after bell
**Path existed:** `setSettlement` only gated on `settled`, so owner could rewire after
`done` but before settle.  
**Closed on the branch before merge:** `SettlementFrozenAfterBell` when `done`;
tests `test_P1_setSettlement_frozenAfterBell` + `test_P3_setSettlement_frozenAfterBell`.

## Legacy retirement
**Retirement hash:** `3058176854cb368d39262a89be056dba487ef2d4`  
- Moved `StonkzAuction`, `IStonkzAuction`, `StonkzAuctionManager` + all their tests
  into `contracts/legacy/` (not deleted — forensic suites import them; nothing in
  live `src/`/`test` imported them).
- Kept shared live deps in `src/`: `LadderWeights`, `CreatorReserveLib` (Express).
- Removed CI jobs: Handler invariant campaign, Differential fuzz consumer
  (both StonkzAuction-only). Live Foundry job is now `forge test` on the live tree.
- Escrow bug preserved in `contracts/legacy/README.md` (seed `0xc7e3…78a9`).
- **Never** in rehearsal/official deploy manifests. Live targets: Express =
  DirectListing, Ladder = StonkzLadderAuction.
