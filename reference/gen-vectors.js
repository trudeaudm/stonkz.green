/**
 * Generate Foundry differential-test vectors from the reference engine.
 * Run: node reference/gen-vectors.js
 *
 * Numeric economic fields are integer 1e18 fixed-point (WAD) strings so
 * Foundry `stdJson.readUint` works without float parsing.
 */
const fs = require('fs');
const path = require('path');
const { createEngine } = require('./engine');

const OUT = path.join(__dirname, '..', 'contracts', 'test', 'vectors');
fs.mkdirSync(OUT, { recursive: true });

function toWad(n) {
  if (typeof n === 'bigint') return (n * 10n ** 18n).toString();
  const x = Number(n);
  if (!Number.isFinite(x)) return '0';
  // Integers within safe range: exact BigInt path (avoids 1e9*1e18 float drift)
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

function write(name, e, blocks, extra = {}) {
  const final = e.state();
  const out = {
    name,
    params: {
      blocks: e.params.blocks,
      supply: toWad(e.params.supply),
      floorMcap: toWad(e.params.floorMcap),
      threshold: toWad(e.params.threshold),
      baseStepBps: Math.round(e.params.baseStepPct * 100),
      walletCapBps: Math.round(e.params.walletCapPct * 100),
      sizeBonusBps: Math.round(e.params.sizeBonusPct * 100),
      lpShareBps: Math.round(e.params.lpSharePct * 100),
      holdbackBps: Math.round(e.params.holdbackPct * 100),
      kappaHundredths: Math.round(e.params.kappa * 100),
    },
    derived: {
      floor: toWad(final.floor),
      launchSupply: toWad(final.launchSupply),
      auctionSupply: toWad(final.auctionSupply),
      reserve: toWad(final.reserve),
      auctPct: toWad(final.auctPct),
      alpha: toWad(final.alpha),
      lpShare: toWad(final.lpShare),
      weights: e.weights(e.params.blocks).map(toWad),
    },
    ...extra,
    bids: final.addrs.map(a => ({
      name: a.name,
      positions: a.positions.map(p => ({
        budget: toWad(p.bud),
        maxPrice: toWad(p.maxP),
        spent: toWad(p.spent),
        tokens: toWad(p.tok),
        status: p.status,
      })),
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
  const file = path.join(OUT, `${name}.json`);
  fs.writeFileSync(file, JSON.stringify(out, null, 2));
  console.log(`wrote ${name}: ${blocks.length} blocks → ${file}`);
}

function runScenario(name, params, setup) {
  const e = createEngine(params);
  setup(e);
  const blocks = [];
  for (let i = 0; i < e.params.blocks && !e.state().done; i++) blocks.push(snapshotBlock(e));
  write(name, e, blocks);
}

function runWithSchedule(name, params, actions) {
  const e = createEngine(params);
  const blocks = [];
  let actionIdx = 0;
  const applyDue = () => {
    while (actionIdx < actions.length && actions[actionIdx].at <= e.state().block) {
      const a = actions[actionIdx++];
      if (a.bid) e.bid(a.bid.name, a.bid.budget, a.bid.maxPrice);
    }
  };
  applyDue();
  for (let i = 0; i < e.params.blocks && !e.state().done; i++) {
    applyDue();
    blocks.push(snapshotBlock(e));
  }
  write(name, e, blocks, {
    actions: actions.map(a => ({
      at: a.at,
      bid: {
        name: a.bid.name,
        budget: toWad(a.bid.budget),
        maxPrice: toWad(a.bid.maxPrice),
      },
    })),
  });
}

runScenario('canonical-abc', {
  blocks: 10, supply: 100, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 0, sizeBonusPct: 0, baseStepPct: 10,
}, e => {
  e.bid('A', 1000, 1e9);
  e.bid('B', 2000, 1e9);
  e.bid('C', 2500, 1e9);
});

runScenario('size-tilt', {
  blocks: 10, supply: 100, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 0, sizeBonusPct: 10, baseStepPct: 10,
}, e => {
  e.bid('A', 1000, 1e9);
  e.bid('B', 2000, 1e9);
});

runWithSchedule('ghost-town-squish', {
  blocks: 10, supply: 100, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 0, sizeBonusPct: 0, baseStepPct: 10,
}, [
  { at: 3, bid: { name: 'A', budget: 1e9, maxPrice: 1e9 } },
  { at: 3, bid: { name: 'B', budget: 1e9, maxPrice: 1e9 } },
]);

runWithSchedule('frozen-book-thaw', {
  blocks: 10, supply: 100, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 0, sizeBonusPct: 0, baseStepPct: 50,
}, [
  { at: 0, bid: { name: 'A', budget: 500, maxPrice: 50.5 } },
  { at: 0, bid: { name: 'B', budget: 500, maxPrice: 50.5 } },
  { at: 4, bid: { name: 'C', budget: 5000, maxPrice: 1e9 } },
  { at: 4, bid: { name: 'D', budget: 5000, maxPrice: 1e9 } },
]);

runScenario('oversubscription-drain', {
  blocks: 20, supply: 1e6, floorMcap: 5000, walletCapPct: 100,
  threshold: 100, lpSharePct: 80, sizeBonusPct: 10, baseStepPct: 0.5, kappa: 1.3,
}, e => {
  for (let i = 0; i < 8; i++) e.bid(e.NAMES[i], 500 + i * 40, 1e9);
});

runScenario('kappa-split', {
  blocks: 5, supply: 1e9, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 80, sizeBonusPct: 0, baseStepPct: 0.2, kappa: 1.3,
}, e => {
  e.bid('A', 10, 1e9);
  e.bid('B', 10, 1e9);
});

runScenario('failure-refund-all', {
  blocks: 5, supply: 100, floorMcap: 5000, walletCapPct: 100,
  // budgets sum to $100 so raised << threshold; threshold must still pass §7 ceiling
  threshold: 2000, lpSharePct: 80, sizeBonusPct: 0, baseStepPct: 10, kappa: 1.3,
}, e => {
  e.bid('A', 50, 1e9);
  e.bid('B', 50, 1e9);
});

console.log('\nAll vectors written to', OUT);
