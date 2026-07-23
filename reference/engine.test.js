/**
 * Reference engine regression suite. Run: node reference/engine.test.js
 * These are the behaviors the Solidity implementation must reproduce.
 */
const { createEngine } = require('./engine');
const assert = require('assert');
let pass = 0;
const ok = (cond, name) => { assert(cond, name); pass++; console.log('✓', name); };

// ---- 1. The canonical A/B/C example: per-capita fills ----
{
  const e = createEngine({ blocks: 10, supply: 100, floorMcap: 100, walletCapPct: 100, threshold: 0, lpSharePct: 0, sizeBonusPct: 0, baseStepPct: 10 });
  // force user's exact example schedule (block1: 100k of 1B ~ scaled here)
  e.bid('A', 100, 1e9); e.bid('B', 200, 1e9); e.bid('C', 250, 1e9);
  e.step(1);
  const t = e.state().addrs.map(a => a.positions[0].tok);
  ok(Math.abs(t[0] - t[1]) < 1e-9 && Math.abs(t[1] - t[2]) < 1e-9, 'per-capita: equal fills regardless of bid size (size bonus 0)');
}

// ---- 2. Size tilt: 2x capital = +bonus% fill ----
{
  const e = createEngine({ blocks: 10, supply: 100, floorMcap: 100, walletCapPct: 100, threshold: 0, lpSharePct: 0, sizeBonusPct: 10 });
  e.bid('A', 100, 1e9); e.bid('B', 200, 1e9);
  e.step(1);
  const [a, b] = e.state().addrs.map(x => x.positions[0].tok);
  ok(Math.abs(b / a - 1.10) < 1e-6, 'size tilt: $200 fills exactly 10% more than $100 per block');
}

// ---- 3. Release curve: 40/60 split, seamless finale handoff, monotone ----
{
  const e = createEngine({});
  for (const N of [10, 50, 200]) {
    const w = e.weights(N), K = Math.floor(N * 0.8);
    const fin = w.slice(K).reduce((x, y) => x + y, 0);
    let mono = true; for (let i = 1; i < N; i++) if (w[i] < w[i - 1] - 1e-12) mono = false;
    ok(Math.abs(fin - 0.6) < 1e-9, `weights(${N}): finale = 60%`);
    ok(Math.abs(w[K] / w[K - 1] - 1) < 1e-9, `weights(${N}): seamless B→C handoff`);
    ok(mono, `weights(${N}): monotone`);
  }
}

// ---- 4. Squish: unsold supply rolls forward; schedule reproduced under full demand ----
{
  const e = createEngine({ blocks: 10, supply: 100, floorMcap: 100, walletCapPct: 100, threshold: 0, lpSharePct: 0, sizeBonusPct: 0 });
  e.bid('A', 1e9, 1e9); e.bid('B', 1e9, 1e9);
  const offs = [];
  for (let i = 0; i < 10; i++) { offs.push(e.offered()); e.step(1); }
  const sched = e.weights(10).map(w => w * 100 * (e.state().auctPct / 100));
  ok(offs.every((o, i) => Math.abs(o - sched[i]) < 1e-6), 'squish == precomputed schedule when everything sells');
}

// ---- 5. Demand-gated price + demand-scaled step ----
{
  const e = createEngine({ blocks: 10, supply: 100, floorMcap: 100, walletCapPct: 100, threshold: 1000, lpSharePct: 0, sizeBonusPct: 0, baseStepPct: 2 });
  e.bid('A', 500, 1e9); // 0.5x graduation committed → step ×1.5
  const p0 = e.state().price;
  e.step(1);
  ok(Math.abs(e.state().price / p0 - 1.03) < 1e-9, 'demand-scaled step: 0.5x grad bid → base 2% becomes 3%');
}

// ---- 6. Committed bids: priced-out capital is claimable, excluded from demand scaling ----
{
  const e = createEngine({ blocks: 10, supply: 100, floorMcap: 100, walletCapPct: 100, threshold: 0, lpSharePct: 0 });
  e.bid('A', 100, 1e-9); // max below floor → priced out immediately
  e.step(1);
  const p = e.state().addrs[0].positions[0];
  ok(p.status === 'out_price' && p.spent === 0, 'priced-out bid: full commit claimable, nothing spent');
}

// ---- 7. κ̂-derived split ----
{
  const e80 = createEngine({ lpSharePct: 80, kappa: 1.3 });
  ok(Math.abs(e80.state().auctPct - 61.9) < 0.1, 'κ̂ split: 80% LP share → 61.9 : 38.1 (the 60:40)');
  const e100 = createEngine({ lpSharePct: 100, kappa: 1.3 });
  ok(Math.abs(e100.state().auctPct - 56.5) < 0.1, 'κ̂ split: 100% LP share → 56.5 : 43.5');
}

// ---- 8. Oversubscription: top-ups sell from reserve, paced (no one-block cliff), guard-safe ----
{
  const e = createEngine({ blocks: 500, supply: 1e9, floorMcap: 5000, walletCapPct: 100, threshold: 5000, lpSharePct: 100, sizeBonusPct: 10, baseStepPct: 0.2 });
  for (let i = 0; i < 25; i++) e.bid(e.NAMES[i], 300 + (i * 37) % 800, 1);
  let prev = 0; const perBlock = []; let violations = 0;
  while (!e.state().done) {
    const st = e.state();
    const slackPre = e.reserveRem() - st.lpShare * st.raised / st.price - st.lpShare * Math.max(0, st.auctionSupply - e.auctionSold()) / st.kappa;
    e.step(1);
    const extra = (e.state().extraSold || 0) - prev; prev = e.state().extraSold || 0;
    if (extra > 1e-9) { perBlock.push(extra); if (slackPre <= 0) violations++; }
  }
  const total = e.state().extraSold || 0;
  if (total > 0) {
    ok(Math.max(...perBlock) / total < 0.2, 'reserve drain paced: no single block > 20% of drain');
  }
  ok(violations === 0, 'top-ups only fire with positive guard slack (never cause insolvency)');
}

// ---- 9. Conservation: every launch token ends in exactly one bucket ----
{
  const e = createEngine({ blocks: 500, supply: 1e9, floorMcap: 5000, walletCapPct: 100, threshold: 3000, lpSharePct: 80, holdbackPct: 10, baseStepPct: 0.2 });
  e.bid('A', 3000, 1); e.bid('B', 3000, 1); e.bid('C', 3000, 1);
  e.runToEnd();
  const s = e.state();
  const rr = e.reserveRem();
  const need = s.lpShare * s.raised / (s.lastSoldPrice || s.price);
  const paired = Math.min(need, rr), surplus = Math.max(0, rr - need);
  const auctionExcess = Math.max(0, s.auctionSupply - e.auctionSold());
  const launch = s.supply * (100 - s.holdbackPct) / 100;
  ok(Math.abs(s.sold + paired + surplus + auctionExcess - launch) < 1, 'conservation: sold + paired + surplus + auctionExcess == launch supply');
}

console.log(`\nALL ${pass} CHECKS PASSED — this is the behavior Solidity must match.`);
