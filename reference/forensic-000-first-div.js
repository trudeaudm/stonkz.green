/**
 * Find first block where Solidity-scale WAD replay (via exact BigInt math proxy)
 * cannot be done in JS easily — instead compare vector cumulative fills vs
 * re-sim engine with WAD→Number params (same as Foundry input path).
 */
const fs = require('fs');
const path = require('path');
const { createEngine } = require('./engine');

const vec = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'contracts', 'test', 'vectors', 'fuzz', 'fuzz-000.json'), 'utf8')
);
const p = vec.params;
const engParams = {
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

const TOL = 1e18;
const e = createEngine(engParams);
let actionIdx = 0;
const applyDue = () => {
  while (actionIdx < vec.actions.length && vec.actions[actionIdx].at <= e.state().block) {
    const a = vec.actions[actionIdx++];
    e.bid(a.bid.name, Number(a.bid.budget) / 1e18, Number(a.bid.maxPrice) / 1e18);
  }
};
applyDue();

function wadRound(x) {
  return BigInt(Math.round(x * 1e18));
}

const rows = [];
for (let i = 0; i < vec.blocks.length && !e.state().done; i++) {
  applyDue();
  const priceB = e.state().price;
  const offB = e.offered();
  const fillsBefore = {};
  e.state().addrs.forEach((a) => {
    fillsBefore[a.name] = a.positions.reduce((s, p) => s + p.tok, 0);
  });
  e.step(1);
  const fills = {};
  e.state().addrs.forEach((a) => {
    const after = a.positions.reduce((s, p) => s + p.tok, 0);
    fills[a.name] = after - (fillsBefore[a.name] || 0);
  });
  const blk = vec.blocks[i];
  const checks = [
    ['price', wadRound(priceB), BigInt(blk.price)],
    ['offered', wadRound(offB), BigInt(blk.offered)],
    ['sold', wadRound(blk.sold ? Number(blk.sold) / 1e18 : 0), BigInt(blk.sold)], // placeholder
    ['raised', wadRound(e.state().raised), BigInt(blk.raised)],
  ];
  // sold from engine hist
  const soldNow = e.state().hist[e.state().hist.length - 1].sold;
  checks[2] = ['sold', wadRound(soldNow), BigInt(blk.sold)];
  for (const name of Object.keys(blk.fills || {})) {
    checks.push([`fill:${name}`, wadRound(fills[name] || 0), BigInt(blk.fills[name])]);
  }
  for (const [field, got, exp] of checks) {
    const d = got > exp ? got - exp : exp - got;
    if (d > BigInt(TOL)) {
      rows.push({
        block: i,
        field,
        got: got.toString(),
        exp: exp.toString(),
        delta: d.toString(),
      });
      console.log('FIRST', JSON.stringify(rows[0], null, 2));
      process.exit(0);
    }
  }
}
console.log('no divergence engine-WAD-replay vs vector at 1e18');
