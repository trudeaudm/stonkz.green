/**
 * Forensic: replay fuzz-000 with STONKZ_TRACE_BLOCK=5, dump water-fill iterations.
 * Usage: STONKZ_TRACE_BLOCK=5 node reference/forensic-000-trace.js
 * (On Windows PowerShell: $env:STONKZ_TRACE_BLOCK=5; node reference/forensic-000-trace.js)
 */
const fs = require('fs');
const path = require('path');

process.env.STONKZ_TRACE_BLOCK = process.env.STONKZ_TRACE_BLOCK || '5';
const { createEngine } = require('./engine');

const vec = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'contracts', 'test', 'vectors', 'fuzz', 'fuzz-000.json'), 'utf8')
);

function fromWad(s) {
  // return Number for engine (engine uses float dollars/tokens)
  return Number(s) / 1e18;
}

const p = vec.params;
const engParams = {
  blocks: p.blocks,
  supply: fromWad(p.supply),
  floorMcap: fromWad(p.floorMcap),
  threshold: fromWad(p.threshold),
  baseStepPct: p.baseStepBps / 100,
  walletCapPct: p.walletCapBps / 100,
  sizeBonusPct: p.sizeBonusBps / 100,
  lpSharePct: p.lpShareBps / 100,
  holdbackPct: p.holdbackBps / 100,
  kappa: p.kappaHundredths / 100,
};

const e = createEngine(engParams);
let actionIdx = 0;
const applyDue = () => {
  while (actionIdx < vec.actions.length && vec.actions[actionIdx].at <= e.state().block) {
    const a = vec.actions[actionIdx++];
    e.bid(a.bid.name, fromWad(a.bid.budget), fromWad(a.bid.maxPrice));
  }
};
applyDue();
while (!e.state().done && e.state().block <= Number(process.env.STONKZ_TRACE_BLOCK)) {
  applyDue();
  e.step(1);
}

const out = {
  traceBlock: Number(process.env.STONKZ_TRACE_BLOCK),
  stateAfter: {
    block: e.state().block,
    price: e.state().price,
    raised: e.state().raised,
    sold: e.state().sold,
  },
  waterFillTrace: e.waterFillTrace,
};
const dest = path.join(__dirname, '..', 'contracts', 'test', 'vectors', 'fuzz', 'forensic-000-ref-trace.json');
fs.writeFileSync(dest, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
console.log('wrote', dest);
