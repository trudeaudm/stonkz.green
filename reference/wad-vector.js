/**
 * Shared WAD helpers for vector generation (quantize-then-snapshot).
 * Draw in float → toWad → fromWad → align floor/cliffs to Solidity mulDiv → re-run → snapshot.
 */
function toWad(n) {
  if (typeof n === 'bigint') return (n * 10n ** 18n).toString();
  const x = Number(n);
  if (!Number.isFinite(x)) return '0';
  if (Number.isInteger(x) && Math.abs(x) <= Number.MAX_SAFE_INTEGER) {
    return (BigInt(x) * 10n ** 18n).toString();
  }
  return BigInt(Math.round(x * 1e18)).toString();
}

function fromWadStr(s) {
  // Prefer exact integer path when the WAD encodes an integer token/dollar amount
  const v = BigInt(s);
  const whole = v / 10n ** 18n;
  const frac = v % 10n ** 18n;
  return Number(whole) + Number(frac) / 1e18;
}

/** Solidity-matching floor price: mulDiv(floorMcap, WAD, supply). */
function solFloorPriceWad(floorMcapWad, supplyWad) {
  return (BigInt(floorMcapWad) * 10n ** 18n) / BigInt(supplyWad);
}

/**
 * Quantize float engine params to WAD domain, then decode for createEngine.
 * Engine initial price is forced to the Solidity mulDiv floor (as Number).
 */
function quantizeParams(params) {
  const wad = {
    blocks: params.blocks,
    supply: toWad(params.supply),
    floorMcap: toWad(params.floorMcap),
    threshold: toWad(params.threshold ?? 0),
    baseStepBps: Math.round((params.baseStepPct ?? 0) * 100),
    walletCapBps: Math.round((params.walletCapPct ?? 100) * 100),
    sizeBonusBps: Math.round((params.sizeBonusPct ?? 0) * 100),
    lpShareBps: Math.round((params.lpSharePct ?? 0) * 100),
    holdbackBps: Math.round((params.holdbackPct ?? 0) * 100),
    kappaHundredths: Math.round((params.kappa ?? 1) * 100),
  };
  const solPrice = solFloorPriceWad(wad.floorMcap, wad.supply);
  const engine = {
    blocks: wad.blocks,
    supply: fromWadStr(wad.supply),
    floorMcap: fromWadStr(wad.floorMcap),
    threshold: fromWadStr(wad.threshold),
    baseStepPct: wad.baseStepBps / 100,
    walletCapPct: wad.walletCapBps / 100,
    sizeBonusPct: wad.sizeBonusBps / 100,
    lpSharePct: wad.lpShareBps / 100,
    holdbackPct: wad.holdbackBps / 100,
    kappa: wad.kappaHundredths / 100,
    excessMode: params.excessMode ?? 'lp',
    // Carry exact sol floor for post-create patch + cliff alignment
    _solPriceWad: solPrice.toString(),
    _solPrice: fromWadStr(solPrice.toString()),
  };
  return { wad, engine };
}

/**
 * Quantize actions. If a bid's float maxPrice was >= float floor (in-the-money at open),
 * ensure stored/engine maxPrice >= Solidity mulDiv floor so cliffs don't flip out-of-price.
 */
function quantizeActions(actions, floatFloor, solPriceWad) {
  const sol = BigInt(solPriceWad);
  const wad = actions.map((a) => {
    let maxW = toWad(a.bid.maxPrice);
    if (floatFloor > 0 && a.bid.maxPrice + 1e-12 >= floatFloor && BigInt(maxW) < sol) {
      maxW = sol.toString();
    }
    return {
      at: a.at,
      bid: {
        name: a.bid.name,
        budget: toWad(a.bid.budget),
        maxPrice: maxW,
      },
    };
  });
  const engine = wad.map((a) => ({
    at: a.at,
    bid: {
      name: a.bid.name,
      budget: fromWadStr(a.bid.budget),
      maxPrice: fromWadStr(a.bid.maxPrice),
    },
  }));
  return { wad, engine };
}

function snapshotBlock(e, toWadFn) {
  const fillsBefore = {};
  e.state().addrs.forEach((a) => {
    fillsBefore[a.name] = a.positions.reduce((s, p) => s + p.tok, 0);
  });
  e.step(1);
  const st2 = e.state();
  const fills = {};
  const statuses = {};
  st2.addrs.forEach((a) => {
    const after = a.positions.reduce((s, p) => s + p.tok, 0);
    fills[a.name] = toWadFn(after - (fillsBefore[a.name] || 0));
    statuses[a.name] = a.positions.map((p) => p.status);
  });
  const hist = st2.hist[st2.hist.length - 1];
  return {
    block: hist.block,
    price: toWadFn(hist.price),
    offered: toWadFn(hist.offered),
    sold: toWadFn(hist.sold),
    fills,
    statuses,
    raised: toWadFn(st2.raised),
    auctionSold: toWadFn(e.auctionSold()),
    extraSold: toWadFn(st2.extraSold || 0),
    reserveRem: toWadFn(e.reserveRem()),
    competition: st2.comp,
    done: st2.done,
    graduated: st2.graduated,
  };
}

/** Patch engine state so opening price matches Solidity mulDiv floor. */
function patchSolFloor(e, engParams) {
  if (!engParams._solPrice) return;
  const st = e.state();
  st.floor = engParams._solPrice;
  st.price = engParams._solPrice;
}

module.exports = {
  toWad,
  fromWadStr,
  solFloorPriceWad,
  quantizeParams,
  quantizeActions,
  snapshotBlock,
  patchSolFloor,
};
