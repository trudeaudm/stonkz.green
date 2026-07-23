/**
 * Seeded differential fuzz vectors for StonkzAuction.
 * Run: node reference/fuzz-vectors.js [seed]
 * Default seed: 4663. Writes 200 WAD JSON scenarios to contracts/test/vectors/fuzz/.
 *
 * Pipeline (Task I — WAD-consistent oracle):
 *   1. Draw params/actions in float (RNG).
 *   2. Quantize to WAD (toWad).
 *   3. Re-run engine on fromWad(quantized) values.
 *   4. Snapshot THAT trajectory to JSON.
 * Stored params, actions, and per-block trajectory all originate from the same quantized run.
 */
const fs = require('fs');
const path = require('path');
const { createEngine } = require('./engine');
const { toWad, quantizeParams, quantizeActions, snapshotBlock, patchSolFloor } = require('./wad-vector');

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

function drawParams() {
  const blocks = ui(5, 30);
  const supply = pick([100, 1e3, 1e6, 1e9]);
  const floorMcap = u(2000, 100000);
  const baseStepPct = chance(0.15) ? 0 : u(0, 5);
  const walletCapPct = u(1, 100);
  const sizeBonusPct = chance(0.2) ? 0 : u(0, 25);
  const holdbackPct = chance(0.25) ? 0 : u(0, 20);
  const lpSharePct = chance(0.1) ? 0 : u(0, 100);
  const kappa = u(1.0, 2.0);
  const launchFrac = (100 - holdbackPct) / 100;
  const auctFrac = kappa / (kappa + lpSharePct / 100);
  const floorRaise = auctFrac * launchFrac * floorMcap;
  let threshold = 0;
  if (chance(0.55)) threshold = 0;
  else if (chance(0.3)) threshold = u(0, floorRaise * 0.5);
  else threshold = u(floorRaise * 0.5, floorRaise * 2.5);
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

  if (chance(0.7)) {
    const nPre = ui(1, Math.min(4, used.length));
    for (let i = 0; i < nPre; i++) {
      actions.push({ at: 0, bid: drawBid(used[i % used.length], floor, params) });
    }
  }

  const nMid = ui(0, 5);
  for (let i = 0; i < nMid; i++) {
    actions.push({ at: ui(1, Math.max(1, N - 1)), bid: drawBid(pick(used), floor, params) });
  }

  if (chance(0.4) && used.length) {
    const who = pick(used);
    actions.push({ at: ui(0, Math.floor(N / 2)), bid: drawBid(who, floor, params) });
    actions.push({ at: ui(0, Math.floor(N / 2)), bid: drawBid(who, floor, params) });
  }

  if (chance(0.35)) {
    const steps = ui(0, 3);
    const cliff = floor * Math.pow(1 + params.baseStepPct / 100, steps);
    actions.push({
      at: ui(0, Math.max(0, Math.floor(N / 3))),
      bid: { name: pick(used), budget: u(10, 5000), maxPrice: cliff },
    });
  }

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
  if (mode === 0) maxPrice = 1e9;
  else if (mode === 1) maxPrice = floor * u(0.5, 0.99);
  else if (mode === 2) maxPrice = floor * u(1.0, 1.0 + params.baseStepPct / 50);
  else maxPrice = floor * u(1, 20);
  return { name, budget: u(10, 8000), maxPrice };
}

/**
 * Quantize float draw → re-run engine on WAD domain → snapshot that trajectory.
 */
function runScenario(index, floatParams, floatActions) {
  const { wad: wadParams, engine: engParams } = quantizeParams(floatParams);
  const floatFloor = floatParams.floorMcap / floatParams.supply;
  const { wad: wadActions, engine: engActions } = quantizeActions(
    floatActions,
    floatFloor,
    engParams._solPriceWad
  );

  const e = createEngine(engParams);
  patchSolFloor(e, engParams);
  const blocks = [];
  let actionIdx = 0;
  const applyDue = () => {
    while (actionIdx < engActions.length && engActions[actionIdx].at <= e.state().block) {
      const a = engActions[actionIdx++];
      try {
        e.bid(a.bid.name, a.bid.budget, a.bid.maxPrice);
      } catch (_) { /* soft fail */ }
    }
  };
  applyDue();
  for (let i = 0; i < engParams.blocks && !e.state().done; i++) {
    applyDue();
    blocks.push(snapshotBlock(e, toWad));
  }
  const final = e.state();
  return {
    name: `fuzz-${String(index).padStart(3, '0')}`,
    seed: SEED,
    index,
    quantized: true,
    params: wadParams,
    actions: wadActions,
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

const names = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
const manifest = { seed: SEED, count: N_SCENARIOS, quantized: true, files: [] };

for (let i = 0; i < N_SCENARIOS; i++) {
  const params = drawParams();
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
console.log(`Done. seed=${SEED} scenarios=${N_SCENARIOS} quantized=true → ${OUT}`);
