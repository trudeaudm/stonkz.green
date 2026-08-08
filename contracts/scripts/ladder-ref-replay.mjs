#!/usr/bin/env node
/**
 * Off-chain reference replay of docs/09 ladder clearing (path prices + sold).
 * Used to lock Phase 1 semantics before / while porting to Solidity.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VEC = path.join(__dirname, "../test/vectors/ladder");

function makeWeights(N) {
  const K = Math.floor(N * 0.8);
  const M = N - K;
  const w = new Array(N);
  let sPre = 0;
  for (let i = 1; i <= K; i++) {
    w[i - 1] = i;
    sPre += i;
  }
  for (let i = 0; i < K; i++) w[i] = (w[i] * 0.4) / sPre;
  if (M === 0) return w;
  const a = w[K - 1];
  const finale = 0.6;
  if (M === 1) {
    w[K] = finale;
  } else if (a * M >= finale) {
    for (let j = 0; j < M; j++) w[K + j] = finale / M;
  } else {
    // geometric — match LadderWeights binary search loosely via closed form iterate
    let lo = 1 + 1e-12,
      hi = 100;
    for (let it = 0; it < 80; it++) {
      const mid = (lo + hi) / 2;
      let sum = 0,
        term = a;
      for (let j = 0; j < M; j++) {
        sum += term;
        term *= mid;
      }
      if (sum > finale) hi = mid;
      else lo = mid;
    }
    const r = (lo + hi) / 2;
    let sFin = 0,
      term = a;
    for (let j = 0; j < M; j++) {
      w[K + j] = term;
      sFin += term;
      term *= r;
    }
    for (let j = 0; j < M; j++) w[K + j] *= finale / sFin;
  }
  return w;
}

function replay(file) {
  const j = JSON.parse(fs.readFileSync(path.join(VEC, file), "utf8"));
  const inn = j.inputs;
  const N = inn.N;
  const supply = inn.supply;
  const auctionSupply = inn.auctionSupply;
  const floorMcap = inn.floorMcap;
  const rungInterval = inn.rungIntervalUsd;
  const lpShare = inn.lpShare;
  const lpHealthTarget = inn.lpHealthTarget;
  const circFrac = 1; // ruled FDV fallback
  const alpha = Math.log2(1 + inn.sizeBonusPct / 100);
  const capTokens = (auctionSupply * inn.walletCapPct) / 100;
  const w = makeWeights(N);

  // wallets
  const wallets = new Map();
  for (const b of j.bids) {
    let a = wallets.get(b.wallet);
    if (!a) {
      a = { budget: 0, spent: 0, tokens: 0, maxPrice: 0, positions: [] };
      wallets.set(b.wallet, a);
    }
    a.budget += b.size;
    a.maxPrice = Math.max(a.maxPrice, b.maxPrice);
    a.positions.push({ size: b.size, maxPrice: b.maxPrice, spent: 0, tokens: 0 });
  }

  let raised = 0;
  let soldTokens = 0;
  let rung = 0; // k such that mcap = floor + k*interval
  let price = (floorMcap + rung * rungInterval) / supply;
  const clearingPath = [];

  function liveBudget(p) {
    let live = 0;
    for (const a of wallets.values()) {
      if (a.maxPrice < p) continue;
      const unspent = a.budget - a.spent;
      if (unspent <= 0) continue;
      const remCapTok = Math.max(0, capTokens - a.tokens);
      const capCash = remCapTok * p;
      live += Math.min(unspent, capCash);
    }
    return live;
  }

  function mmax(p) {
    const live = liveBudget(p);
    return floorMcap + (lpShare * (raised + live)) / (lpHealthTarget * circFrac);
  }

  function fillPeriod(offered, p) {
    // Active wallets with maxPrice >= p and unspent and cap room
    const actives = [];
    for (const [name, a] of wallets) {
      if (a.maxPrice < p) continue;
      const unspent = a.budget - a.spent;
      if (unspent <= 0) continue;
      const remCapTok = Math.max(0, capTokens - a.tokens);
      if (remCapTok <= 0) continue;
      const capital = a.budget; // weight uses committed capital (docs/09 §4)
      const weight = Math.pow(Math.max(1, capital), alpha);
      actives.push({ name, a, weight, unspent, remCapTok });
    }
    if (actives.length === 0) return 0;

    let remaining = offered;
    let sold = 0;
    // water-fill style: iterate until remaining ~0 or no actives
    // Simple proportional in one shot with cap clamps — iterate a few times
    for (let iter = 0; iter < 32 && remaining > 1e-9; iter++) {
      const live = actives.filter((x) => {
        const uns = x.a.budget - x.a.spent;
        const rem = Math.max(0, capTokens - x.a.tokens);
        return uns > 1e-12 && rem > 1e-12 && x.a.maxPrice >= p;
      });
      if (live.length === 0) break;
      const sumW = live.reduce((s, x) => s + x.weight, 0);
      let used = 0;
      for (const x of live) {
        let share = (remaining * x.weight) / sumW;
        const uns = x.a.budget - x.a.spent;
        const remTok = Math.max(0, capTokens - x.a.tokens);
        const maxTokCash = remTok; // tokens
        const maxTokBudget = uns / p;
        const maxTok = Math.min(share, maxTokCash, maxTokBudget);
        if (maxTok <= 0) continue;
        x.a.tokens += maxTok;
        x.a.spent += maxTok * p;
        sold += maxTok;
        used += maxTok;
      }
      remaining = offered - sold;
      if (used < 1e-12) break;
    }
    raised += sold * p;
    soldTokens += sold;
    return sold;
  }

  for (let b = 1; b <= N; b++) {
    const offered = auctionSupply * w[b - 1];
    const sold = fillPeriod(offered, price);
    clearingPath.push({ block: b, price, offered, sold });
    // advance one rung if sold > 0 and next rung mcap <= Mmax
    if (sold > 0) {
      const mm = mmax(price); // use post-fill state
      const nextMcap = floorMcap + (rung + 1) * rungInterval;
      if (nextMcap <= mm + 1e-9) {
        rung += 1;
        price = (floorMcap + rung * rungInterval) / supply;
      }
    }
  }

  return { clearingPath, raised, soldTokens, clearingPrice: price, expected: j };
}

function compare(file) {
  const { clearingPath, raised, soldTokens, clearingPrice, expected } = replay(file);
  let priceMismatches = 0;
  let maxPriceDiff = 0;
  const exp = expected.clearingPath;
  for (let i = 0; i < exp.length; i++) {
    const d = Math.abs(clearingPath[i].price - exp[i].price);
    if (d > 1e-18) {
      priceMismatches++;
      maxPriceDiff = Math.max(maxPriceDiff, d);
      if (priceMismatches <= 3) {
        console.log(
          `  price mismatch @${i + 1}: got ${clearingPath[i].price} exp ${exp[i].price} sold got ${clearingPath[i].sold} exp ${exp[i].sold}`
        );
      }
    }
  }
  const relRaised = Math.abs(raised - expected.outputs.raised) / expected.outputs.raised;
  const relSold = Math.abs(soldTokens - expected.outputs.soldTokens) / expected.outputs.soldTokens;
  console.log(
    `${file}: priceMismatches=${priceMismatches} maxPriceDiff=${maxPriceDiff} relRaised=${relRaised.toExponential(3)} relSold=${relSold.toExponential(3)} clearP got=${clearingPrice} exp=${expected.outputs.clearingPrice}`
  );
}

const files = [
  "02-god-2p5k-at-bar.json",
  "04-4h-5k-at-bar.json",
  "05-daily-10k-at-bar.json",
  "07-road-40k-at-bar.json",
  "03-god-5k-oversub.json",
  "10-wallet-cap-binding.json",
];
for (const f of files) compare(f);
