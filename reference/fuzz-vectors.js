/**
 * Seeded differential fuzz vectors for StonkzAuction.
 * Run: node reference/fuzz-vectors.js [seed]
 * Default seed: 4663. Writes 200 WAD JSON scenarios to contracts/test/vectors/fuzz/.
 */
const fs = require('fs');
const path = require('path');
const { createEngine } = require('./engine');

const SEED = Number(process.argv[2] ?? 4663);
const N_SCENARIOS = 200;
const OUT = path.join(__dirname, '..', 'contracts', 'test', 'vectors', 'fuzz');
fs.mkdirSync(OUT, { recursive: true });

/** xorshift32 */
function makeRng(seed) {
  let x = (seed >>> 0) || 4663;
  return () => {
    x ^= x << 13; x >>>= 0;
    x ^= x >>> 17; x >>>= 0;
    x ^= x << 5;  x >>>= 0;
    return (x >>> 0) / 0x100000000;
  };
}

const rand = makeRng(SEED);
const u = (a, b) => a + rand() * (b - a);
const ui = (a, b) => Math.floor(u(a, b + 1));
const pick = (arr) => arr[ui(0, arr.length - 1)];
const chance = (p) => rand() < p;

function toWad(n) {
  if (typeof n === 'bigint') return (n * 10n ** 18n).toString();
  const x = Number(n);
  if (!Number.isFinite(x)) return '0';
  if (Number.isInteger(x) && Math.abs(x) <= Number.MAX_SAFE_INTEGER) {
    return (BigInt(x) * 10n ** 18n).toString();
  }
  return BigInt(Math.round(x * 1e18)).toString();
}

function snapshotBlock(e) {
  const fillsBefore = {};
  e.state().addrs.forEach(a => {
    fillsBefore[a.name] = a.positions.reduce((s, p) => s + p.tok, 0);
  });
  e.step(1);
  const st2 = e.state();
  const fills = {};
  const statuses = {};
  st2.addrs.forEach(a => {
    const after = a.positions.reduce((s, p) => s + p.tok, 0);
    fills[a.name] = toWad(after - (fillsBefore[a.name] || 0));
    statuses[a.name] = a.positions.map(p => p.status);
  });
  const hist = st2.hist[st2.hist.length - 1];
  return {
    block: hist.block,
    price: toWad(hist.price),
    offered: toWad(hist.offered),
    sold: toWad(hist.sold),
    fills,
    statuses,
    raised: toWad(st2.raised),
    auctionSold: toWad(e.auctionSold()),
    extraSold: toWad(st2.extraSold || 0),
    reserveRem: toWad(e.reserveRem()),
    competition: st2.comp,
    done: st2.done,
    graduated: st2.graduated,
  };
}

function drawParams() {
  // Full valid ranges; zeros semantically allowed where valid
  const blocks = ui(5, 30);
  const supply = pick([100, 1e3, 1e6, 1e9]);
  const floorMcap = u(2000, 100000);
  const baseStepPct = chance(0.15) ? 0 : u(0, 5); // include 0
  const walletCapPct = u(1, 100);
  const sizeBonusPct = chance(0.2) ? 0 : u(0, 25);
  const holdbackPct = chance(0.25) ? 0 : u(0, 20);
  const lpSharePct = chance(0.1) ? 0 : u(0, 100);
  const kappa = u(1.0, 2.0);
  // threshold: 0 often; else within a soft band of floor raise
  const launchFrac = (100 - holdbackPct) / 100;
  const auctFrac = kappa / (kappa + lpSharePct / 100);
  const floorRaise = (auctFrac * launchFrac * floorMcap * supply) / supply; // = auctFrac*launchFrac*floorMcap
  let threshold = 0;
  if (chance(0.55)) threshold = 0;
  else if (chance(0.3)) threshold = u(0, floorRaise * 0.5);
  else threshold = u(floorRaise * 0.5, floorRaise * 2.5); // may fail graduation
  return {
    blocks, supply, floorMcap, baseStepPct, walletCapPct, threshold,
    lpSharePct, holdbackPct, sizeBonusPct, kappa, excessMode: 'lp',
  };
}

function drawActions(params, names) {
  const actions = [];
  const N = params.blocks;
  const floor = params.floorMcap / params.supply;
  const nAddrs = ui(1, Math.min(8, names.length));
  const used = names.slice(0, nAddrs);

  // Pre-start bids
  if (chance(0.7)) {
    const nPre = ui(1, Math.min(4, used.length));
    for (let i = 0; i < nPre; i++) {
      actions.push({
        at: 0,
        bid: drawBid(used[i % used.length], floor, params),
      });
    }
  }

  // Mid-auction entries
  const nMid = ui(0, 5);
  for (let i = 0; i < nMid; i++) {
    const at = ui(1, Math.max(1, N - 1));
    actions.push({
      at,
      bid: drawBid(pick(used), floor, params),
    });
  }

  // Multi-bid same address
  if (chance(0.4) && used.length) {
    const who = pick(used);
    actions.push({ at: ui(0, Math.floor(N / 2)), bid: drawBid(who, floor, params) });
    actions.push({ at: ui(0, Math.floor(N / 2)), bid: drawBid(who, floor, params) });
  }

  // Max-price cliffs at exact ladder multiples of floor
  if (chance(0.35)) {
    const steps = ui(0, 3);
    const cliff = floor * Math.pow(1 + params.baseStepPct / 100, steps);
    actions.push({
      at: ui(0, Math.max(0, Math.floor(N / 3))),
      bid: {
        name: pick(used),
        budget: u(10, 5000),
        maxPrice: cliff, // exact tick
      },
    });
  }

  // Post-graduation-ish late entries (late blocks)
  if (chance(0.3)) {
    actions.push({
      at: Math.max(0, N - ui(1, Math.min(5, N))),
      bid: drawBid(pick(used), floor, params),
    });
  }

  actions.sort((a, b) => a.at - b.at || a.bid.name.localeCompare(b.bid.name));
  return actions;
}

function drawBid(name, floor, params) {
  let maxPrice;
  const mode = ui(0, 3);
  if (mode === 0) maxPrice = 1e9; // always in
  else if (mode === 1) maxPrice = floor * u(0.5, 0.99); // priced out immediately
  else if (mode === 2) maxPrice = floor * u(1.0, 1.0 + params.baseStepPct / 50); // near cliff
  else maxPrice = floor * u(1, 20);
  return {
    name,
    budget: u(10, 8000),
    maxPrice,
  };
}

function runScenario(index, params, actions) {
  const e = createEngine(params);
  const blocks = [];
  let actionIdx = 0;
  const applyDue = () => {
    while (actionIdx < actions.length && actions[actionIdx].at <= e.state().block) {
      const a = actions[actionIdx++];
      try {
        e.bid(a.bid.name, a.bid.budget, a.bid.maxPrice);
      } catch (_) { /* ignore engine soft fails */ }
    }
  };
  applyDue();
  for (let i = 0; i < params.blocks && !e.state().done; i++) {
    applyDue();
    blocks.push(snapshotBlock(e));
  }
  const final = e.state();
  return {
    name: `fuzz-${String(index).padStart(3, '0')}`,
    seed: SEED,
    index,
    params: {
      blocks: params.blocks,
      supply: toWad(params.supply),
      floorMcap: toWad(params.floorMcap),
      threshold: toWad(params.threshold),
      baseStepBps: Math.round(params.baseStepPct * 100),
      walletCapBps: Math.round(params.walletCapPct * 100),
      sizeBonusBps: Math.round(params.sizeBonusPct * 100),
      lpShareBps: Math.round(params.lpSharePct * 100),
      holdbackBps: Math.round(params.holdbackPct * 100),
      kappaHundredths: Math.round(params.kappa * 100),
    },
    actions: actions.map(a => ({
      at: a.at,
      bid: {
        name: a.bid.name,
        budget: toWad(a.bid.budget),
        maxPrice: toWad(a.bid.maxPrice),
      },
    })),
    blocks,
    final: {
      sold: toWad(final.sold),
      raised: toWad(final.raised),
      price: toWad(final.price),
      lastSoldPrice: toWad(final.lastSoldPrice || 0),
      extraSold: toWad(final.extraSold || 0),
      auctionSold: toWad(e.auctionSold()),
      reserveRem: toWad(e.reserveRem()),
      done: final.done,
      graduated: final.graduated,
      block: final.block,
    },
  };
}

const names = ['A','B','C','D','E','F','G','H'];
const manifest = { seed: SEED, count: N_SCENARIOS, files: [] };

for (let i = 0; i < N_SCENARIOS; i++) {
  const params = drawParams();
  // Skip construct-impossible thresholds loosely: engine has no ctor check; Solidity does.
  // Cap threshold to a generous ceiling estimate for Solidity constructability.
  const floor = params.floorMcap / params.supply;
  const kappa = params.kappa;
  const lp = params.lpSharePct / 100;
  const launch = params.supply * (100 - params.holdbackPct) / 100;
  const auct = launch * kappa / (kappa + lp);
  let p = floor;
  const hot = 1 + 2 * (params.baseStepPct / 100);
  let ceiling = 0;
  const wEngine = createEngine({ blocks: params.blocks, supply: 100, floorMcap: 5000 }).weights(params.blocks);
  for (let b = 0; b < params.blocks; b++) {
    ceiling += auct * wEngine[b] * p;
    p *= Math.max(hot, 1);
  }
  if (params.threshold > ceiling) params.threshold = ceiling * 0.9;

  const actions = drawActions(params, names);
  const out = runScenario(i, params, actions);
  const file = `fuzz-${String(i).padStart(3, '0')}.json`;
  fs.writeFileSync(path.join(OUT, file), JSON.stringify(out));
  manifest.files.push(file);
  if ((i + 1) % 50 === 0) console.log(`wrote ${i + 1}/${N_SCENARIOS}`);
}

fs.writeFileSync(path.join(OUT, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log(`Done. seed=${SEED} scenarios=${N_SCENARIOS} → ${OUT}`);
