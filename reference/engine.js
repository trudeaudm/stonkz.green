/**
 * STONKZ Ladder Auction — reference engine (the differential-testing oracle).
 * Wraps the verified simulator source (sim-source.js) with a stubbed DOM and
 * exposes a parameter-driven API. Every rule here was validated interactively;
 * Solidity behavior MUST match this engine (see docs/mechanism-spec.md).
 */
const fs = require('fs');
const path = require('path');

/** Finite-number param pick — explicit 0 survives (never `params.x || default`). */
function numParam(params, key, def) {
  if (!Object.prototype.hasOwnProperty.call(params, key)) return def;
  const n = Number(params[key]);
  return Number.isFinite(n) ? n : def;
}

function strParam(params, key, def) {
  if (!Object.prototype.hasOwnProperty.call(params, key)) return def;
  const v = params[key];
  return (v !== undefined && v !== null && v !== '') ? v : def;
}

function createEngine(params = {}) {
  // Defaults only when key absent / non-finite — zeros are semantically valid
  const P = {
    blocks: numParam(params, 'blocks', 500),
    supply: numParam(params, 'supply', 1e9),
    floorMcap: numParam(params, 'floorMcap', 5000),
    baseStepPct: numParam(params, 'baseStepPct', 0.2),
    walletCapPct: numParam(params, 'walletCapPct', 10),
    threshold: numParam(params, 'threshold', 5000),
    lpSharePct: numParam(params, 'lpSharePct', 80),
    holdbackPct: numParam(params, 'holdbackPct', 0),
    excessMode: strParam(params, 'excessMode', 'lp'),
    sizeBonusPct: numParam(params, 'sizeBonusPct', 10),
    kappa: numParam(params, 'kappa', 1.3),
  };

  const mkEl = () => ({ innerHTML:'', textContent:'', value:'', scrollTop:0, scrollHeight:0, className:'' });
  const els = {};
  const doc = { getElementById: id => els[id] || (els[id] = mkEl()) };
  els['c-n']  = { value: String(P.blocks) };
  els['c-s']  = { value: String(P.supply) };
  els['c-p']  = { value: String(P.floorMcap) };
  els['c-g']  = { value: String(P.baseStepPct) };
  els['c-w']  = { value: String(P.walletCapPct) };
  els['c-t']  = { value: String(P.threshold) };
  els['c-ms'] = { value: '450' };
  els['c-lp'] = { value: String(P.lpSharePct) };
  els['c-hb'] = { value: String(P.holdbackPct) };
  els['c-x']  = { value: P.excessMode };
  els['c-sb'] = { value: String(P.sizeBonusPct) };
  els['c-k']  = { value: String(P.kappa) };
  ['b-who','b-bud','b-max','banner','splitshow','stats','chart1','chart2','btbody','log','pausebtn'].forEach(i => els[i] = mkEl());

  const logs = [];
  const sandbox = {
    document: doc, setInterval: () => 0, clearInterval: () => {},
    Math, console, logs,
  };
  let src = fs.readFileSync(path.join(__dirname, 'sim-source.js'), 'utf8');
  src = src.replace(/function log\(m\)\{[^}]*\}/, 'function log(m){logs.push(m)}');
  const expose = ';__x={newSim,addBid,tick,reserveRem,auctionSold,schedFor,offeredFor,makeWeights,committedLive,effStep,getS:()=>S,setS:v=>{S=v},NAMES};';
  const fn = new Function(...Object.keys(sandbox), src + expose + 'return __x;');
  const api = fn(...Object.values(sandbox));

  api.setS(api.newSim());
  const st = api.getS();
  st.flatBase = st.auctionSupply * st.w[0];

  return {
    params: P,
    logs,
    state: () => api.getS(),
    weights: api.makeWeights,
    bid: (name, budget, maxPrice) => api.addBid(name, budget, maxPrice),
    step: (n = 1) => { for (let i = 0; i < n && !api.getS().done; i++) api.tick(); return api.getS(); },
    runToEnd: (max = 10000) => { let i = 0; while (!api.getS().done && i++ < max) api.tick(); return api.getS(); },
    reserveRem: () => api.reserveRem(api.getS()),
    auctionSold: () => api.auctionSold(api.getS()),
    offered: () => api.offeredFor(api.getS()),
    sched: () => api.schedFor(api.getS()),
    NAMES: api.NAMES,
  };
}

module.exports = { createEngine };
