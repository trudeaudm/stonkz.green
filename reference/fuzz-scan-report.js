/**
 * Report-only differential scan of all fuzz vectors (no halt).
 * Usage: node reference/fuzz-scan-report.js
 * Writes contracts/test/vectors/fuzz/scan-report.json
 *
 * Compares reference engine replay vs recorded vector raised/price/offered/sold
 * at each block — isolates which scenarios diverge from the *recorded* oracle
 * vectors when re-simulated (sanity) AND prepares a Foundry-facing checklist.
 *
 * For Solidity vs reference divergence, use forge test ForensicScan (below) or
 * the companion script that shells out — this JS scan verifies vector integrity
 * and flags high-risk param patterns for the Solidity consumer report.
 */
const fs = require('fs');
const path = require('path');
const { createEngine } = require('./engine');

const DIR = path.join(__dirname, '..', 'contracts', 'test', 'vectors', 'fuzz');
const manifest = JSON.parse(fs.readFileSync(path.join(DIR, 'manifest.json'), 'utf8'));
const TOL = 1e18; // same absolute scale as Foundry (WAD units as integers in JSON)

function fromWadStr(s) {
  return BigInt(s);
}

function absDiff(a, b) {
  return a > b ? a - b : b - a;
}

function engParamsFromVec(p) {
  return {
    blocks: p.blocks,
    supply: Number(p.supply) / 1e18,
    floorMcap: Number(p.floorMcap) / 1e18,
    threshold: Number(p.threshold) / 1e18,
    baseStepPct: p.baseStepBps / 100,
    walletCapPct: p.walletCapBps / 100,
    sizeBonusPct: p.sizeBonusBps / 100,
    lpSharePct: p.lpShareBps / 100,
    holdbackPct: p.holdbackBps / 100,
    kappa: p.kappaHundredths / 100,
  };
}

/** Re-sim vector actions; compare to stored block snapshots (oracle self-consistency). */
function scanSelfConsistency(vec) {
  const e = createEngine(engParamsFromVec(vec.params));
  let actionIdx = 0;
  const applyDue = () => {
    while (actionIdx < vec.actions.length && vec.actions[actionIdx].at <= e.state().block) {
      const a = vec.actions[actionIdx++];
      try {
        e.bid(a.bid.name, Number(a.bid.budget) / 1e18, Number(a.bid.maxPrice) / 1e18);
      } catch (_) {}
    }
  };
  applyDue();
  for (let i = 0; i < vec.blocks.length && !e.state().done; i++) {
    applyDue();
    const priceBefore = e.state().price;
    const offeredBefore = e.offered();
    e.step(1);
    const blk = vec.blocks[i];
    const raisedGot = BigInt(Math.round(e.state().raised * 1e18));
    const raisedExp = fromWadStr(blk.raised);
    if (absDiff(raisedGot, raisedExp) > BigInt(TOL)) {
      return { block: i, field: 'raised-self', magnitude: absDiff(raisedGot, raisedExp).toString() };
    }
    const priceExp = fromWadStr(blk.price);
    const priceGot = BigInt(Math.round(priceBefore * 1e18));
    if (absDiff(priceGot, priceExp) > BigInt(TOL)) {
      return { block: i, field: 'price-self', magnitude: absDiff(priceGot, priceExp).toString() };
    }
    const offExp = fromWadStr(blk.offered);
    const offGot = BigInt(Math.round(offeredBefore * 1e18));
    if (absDiff(offGot, offExp) > BigInt(TOL)) {
      return { block: i, field: 'offered-self', magnitude: absDiff(offGot, offExp).toString() };
    }
  }
  return null;
}

function flags(vec) {
  const p = vec.params;
  const multiBid = {};
  for (const a of vec.actions) {
    multiBid[a.bid.name] = (multiBid[a.bid.name] || 0) + 1;
  }
  const hasMulti = Object.values(multiBid).some((n) => n > 1);
  return {
    tightWalletCap: p.walletCapBps < 2000,
    sizeBonusPos: p.sizeBonusBps > 0,
    multiBid: hasMulti,
    baseStepZero: p.baseStepBps === 0,
    holdbackPos: p.holdbackBps > 0,
  };
}

const rows = [];
for (let i = 0; i < manifest.files.length; i++) {
  const file = manifest.files[i];
  const vec = JSON.parse(fs.readFileSync(path.join(DIR, file), 'utf8'));
  const selfHit = scanSelfConsistency(vec);
  rows.push({
    scenario: i,
    file,
    selfConsistencyOk: !selfHit,
    selfDivergence: selfHit,
    flags: flags(vec),
    // Placeholder filled by forge forensic scan script output if present
    solidityDivergence: null,
  });
}

const out = {
  seed: manifest.seed,
  count: rows.length,
  note:
    'selfConsistency = re-sim engine vs stored vector. Solidity vs reference filled by forge test ForensicScanReport.',
  rows,
};
fs.writeFileSync(path.join(DIR, 'scan-report-self.json'), JSON.stringify(out, null, 2));
console.log('self-consistency divergences', rows.filter((r) => !r.selfConsistencyOk).length);
console.log('wrote scan-report-self.json');
