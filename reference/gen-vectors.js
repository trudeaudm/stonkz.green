/**
 * Generate Foundry differential-test vectors from the reference engine.
 * Run: node reference/gen-vectors.js
 *
 * Pipeline (Task I — WAD-consistent oracle):
 *   Draw params/actions in float → quantize toWad → re-run on fromWad → snapshot THAT trajectory.
 * Numeric economic fields are integer 1e18 fixed-point (WAD) strings for stdJson.readUint.
 */
const fs = require('fs');
const path = require('path');
const { createEngine } = require('./engine');
const { toWad, quantizeParams, quantizeActions, snapshotBlock, patchSolFloor } = require('./wad-vector');

const OUT = path.join(__dirname, '..', 'contracts', 'test', 'vectors');
fs.mkdirSync(OUT, { recursive: true });

function write(name, engParams, wadParams, e, blocks, extra = {}) {
  const final = e.state();
  const out = {
    name,
    quantized: true,
    params: wadParams,
    derived: {
      floor: toWad(final.floor),
      launchSupply: toWad(final.launchSupply),
      auctionSupply: toWad(final.auctionSupply),
      reserve: toWad(final.reserve),
      auctPct: toWad(final.auctPct),
      alpha: toWad(final.alpha),
      lpShare: toWad(final.lpShare),
      weights: e.weights(engParams.blocks).map(toWad),
    },
    ...extra,
    bids: final.addrs.map((a) => ({
      name: a.name,
      positions: a.positions.map((p) => ({
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

function runScenario(name, floatParams, setup) {
  const { wad: wadParams, engine: engParams } = quantizeParams(floatParams);
  const e = createEngine(engParams);
  patchSolFloor(e, engParams);
  const floatFloor = floatParams.floorMcap / floatParams.supply;
  const origBid = e.bid.bind(e);
  e.bid = (name, budget, maxPrice) => {
    let maxW = toWad(maxPrice);
    if (maxPrice + 1e-12 >= floatFloor && BigInt(maxW) < BigInt(engParams._solPriceWad)) {
      maxW = engParams._solPriceWad;
    }
    const qb = Number(BigInt(toWad(budget))) / 1e18;
    const qm = Number(BigInt(maxW)) / 1e18;
    return origBid(name, qb, qm);
  };
  setup(e);
  const blocks = [];
  for (let i = 0; i < engParams.blocks && !e.state().done; i++) {
    blocks.push(snapshotBlock(e, toWad));
  }
  write(name, engParams, wadParams, e, blocks);
}

function runWithSchedule(name, floatParams, floatActions) {
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
      if (a.bid) e.bid(a.bid.name, a.bid.budget, a.bid.maxPrice);
    }
  };
  applyDue();
  for (let i = 0; i < engParams.blocks && !e.state().done; i++) {
    applyDue();
    blocks.push(snapshotBlock(e, toWad));
  }
  write(name, engParams, wadParams, e, blocks, { actions: wadActions });
}

runScenario('canonical-abc', {
  blocks: 10, supply: 100, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 0, sizeBonusPct: 0, baseStepPct: 10,
}, (e) => {
  e.bid('A', 1000, 1e9);
  e.bid('B', 2000, 1e9);
  e.bid('C', 2500, 1e9);
});

runScenario('size-tilt', {
  blocks: 10, supply: 100, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 0, sizeBonusPct: 10, baseStepPct: 10,
}, (e) => {
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
}, (e) => {
  for (let i = 0; i < 8; i++) e.bid(e.NAMES[i], 500 + i * 40, 1e9);
});

runScenario('kappa-split', {
  blocks: 5, supply: 1e9, floorMcap: 5000, walletCapPct: 100,
  threshold: 0, lpSharePct: 80, sizeBonusPct: 0, baseStepPct: 0.2, kappa: 1.3,
}, (e) => {
  e.bid('A', 10, 1e9);
  e.bid('B', 10, 1e9);
});

runScenario('failure-refund-all', {
  blocks: 5, supply: 100, floorMcap: 5000, walletCapPct: 100,
  threshold: 2000, lpSharePct: 80, sizeBonusPct: 0, baseStepPct: 10, kappa: 1.3,
}, (e) => {
  e.bid('A', 50, 1e9);
  e.bid('B', 50, 1e9);
});

console.log('\nAll vectors written to', OUT);
