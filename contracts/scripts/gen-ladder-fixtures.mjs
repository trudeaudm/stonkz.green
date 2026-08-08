#!/usr/bin/env node
/**
 * gen-ladder-fixtures.mjs — regenerate Solidity-consumable ladder fixtures from
 * authoritative vectors at test/vectors/ladder/*.json (schema stonkz-ladder-vector/1).
 *
 * NEVER modify the source vectors. Fixtures are derived outputs only.
 *
 * Choice (Phase 0): pre-generated integerized JSON fixtures (WAD / bps strings),
 * not ffi and not megabyte .sol codegen for 10×1000 clearingPath rows.
 * Checked-in JSON + vm.readFile is CI-deterministic; this script is the
 * reproducible regeneration path.
 *
 * Units: money + prices → WAD (1e18); percents → bps (1e4); token counts →
 * integer wei of the token (18-decimal convention via same toWad helper when
 * the sim emits fractional token floats).
 *
 * Usage (from contracts/): node scripts/gen-ladder-fixtures.mjs
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const SRC = path.join(ROOT, "test/vectors/ladder");
const OUT = path.join(ROOT, "test/fixtures/ladder");
const MANIFEST = path.join(OUT, "manifest.json");

const WAD = 10n ** 18n;

/**
 * Decimal-aware float → WAD integer (nearest).
 * Snaps via 12-dp rounding first to kill float64 dust on clean lab decimals
 * (0.91, 0.6, 0.25, …) while preserving money/token magnitudes within 1e-9 rel.
 */
function toWad(n) {
  if (n === null || n === undefined) return "0";
  if (typeof n === "string" && /^-?\d+$/.test(n)) return n;
  const x = Number(n);
  if (!Number.isFinite(x)) throw new Error(`non-finite: ${n}`);
  // Snap to 12 decimal places (1e-12 abs on unit-scale; money still << 1e-9 rel).
  const snapped = Math.round(x * 1e12) / 1e12;
  const s = snapped.toFixed(12);
  const neg = s.startsWith("-");
  const body = neg ? s.slice(1) : s;
  const [ip, fp = ""] = body.split(".");
  const frac = (fp + "0".repeat(18)).slice(0, 18);
  const v = BigInt(ip) * WAD + BigInt(frac);
  return (neg ? -v : v).toString();
}

/** Percent number (e.g. 4) → bps. `pct` is in percent units (4 = 4%). */
function pctToBps(pct) {
  return Math.round(Number(pct) * 100).toString();
}

/** Fraction 0..1 → WAD via integer bps when it lands on 1 bp; else toWad. */
function fracToWad(f) {
  const bps = Math.round(Number(f) * 10_000);
  if (Math.abs(Number(f) * 10_000 - bps) < 1e-9) {
    return ((BigInt(bps) * WAD) / 10_000n).toString();
  }
  return toWad(f);
}

/** bps → WAD fraction. */
function bpsToWad(bps) {
  return ((BigInt(bps) * WAD) / 10_000n).toString();
}

/** entryBest/entryWorst are {wallet, avgPrice} objects in the pinned schema. */
function entryStat(e) {
  if (e === null || e === undefined) return { wallet: "", avgPrice: "0" };
  if (typeof e === "number") return { wallet: "", avgPrice: toWad(e) };
  return { wallet: String(e.wallet ?? ""), avgPrice: toWad(e.avgPrice ?? 0) };
}

function walletKey(w) {
  // Stable address derivation matching Solidity keccak256(bytes(name)) → address
  return w;
}

function convertVector(raw, fileName) {
  if (raw.schema !== "stonkz-ladder-vector/1") {
    throw new Error(`${fileName}: unexpected schema ${raw.schema}`);
  }
  const inn = raw.inputs;
  const out = raw.outputs;

  const inputs = {
    N: String(inn.N),
    auctionSupply: toWad(inn.auctionSupply),
    cashHoldbackBps: pctToBps(inn.cashHoldbackPct),
    epochSeconds: inn.epochSeconds === null || inn.epochSeconds === undefined || inn.epochSeconds === ""
      ? "0"
      : String(inn.epochSeconds),
    floorMcap: toWad(inn.floorMcap),
    floorPrice: toWad(inn.floorPrice),
    holdbackDelivery: String(inn.holdbackDelivery),
    holdbackBps: pctToBps(inn.holdbackPct),
    leftoverMode: String(inn.leftoverMode),
    lpHealthTarget: fracToWad(inn.lpHealthTarget),
    lpShareBps: Math.round(Number(inn.lpShare) * 10_000).toString(),
    lpShare: bpsToWad(Math.round(Number(inn.lpShare) * 10_000)),
    maxRungsPerBlock: String(inn.maxRungsPerBlock),
    protocolCarveBps: pctToBps(inn.protocolCarvePct),
    raiseRatioBps: Math.round(Number(inn.raiseRatio) * 10_000).toString(),
    raiseRatio: bpsToWad(Math.round(Number(inn.raiseRatio) * 10_000)),
    reserve: toWad(inn.reserve),
    rungIntervalUsd: toWad(inn.rungIntervalUsd),
    sidePoolBps: pctToBps(inn.sidePoolPct),
    sizeBonusBps: pctToBps(inn.sizeBonusPct),
    supply: toWad(inn.supply),
    threshold: toWad(inn.threshold),
    tier: String(inn.tier),
    walletCapBps: pctToBps(inn.walletCapPct),
    // kappaHat display-only — omitted from fixture per docs/09 §8
  };

  const bids = raw.bids.map((b) => ({
    wallet: walletKey(b.wallet),
    size: toWad(b.size),
    maxPrice: toWad(b.maxPrice),
    block: String(b.block), // sim period index
  }));

  // clearingPath: keep full path for A5; money fields in WAD
  const clearingPath = raw.clearingPath.map((r) => ({
    block: String(r.block),
    price: toWad(r.price),
    offered: toWad(r.offered),
    sold: toWad(r.sold),
    phase: String(r.phase),
  }));

  // Raise-split: stamp treasury+LP from float, creator = remainder so
  // toLP+toTreasury+toCreator == raised EXACTLY (docs/09 §7 invariant shape).
  const raisedW = BigInt(toWad(out.raised));
  const toTreasuryW = BigInt(toWad(out.raiseSplit.toTreasury));
  const toLPW = BigInt(toWad(out.raiseSplit.toLP));
  let toCreatorW = raisedW - toTreasuryW - toLPW;
  if (toCreatorW < 0n) {
    // Float dust overflow — trim LP by the deficit (treasury stamped first).
    toCreatorW = 0n;
  }

  const outputs = {
    raised: raisedW.toString(),
    committed: toWad(out.committed),
    raiseSplit: {
      toLP: (raisedW - toTreasuryW - toCreatorW).toString(),
      toTreasury: toTreasuryW.toString(),
      toCreator: toCreatorW.toString(),
    },
    fills: out.fills.map((f) => ({
      wallet: walletKey(f.wallet),
      committed: toWad(f.committed),
      spent: toWad(f.spent),
      tokens: toWad(f.tokens),
      refund: toWad(f.refund),
      positions: (f.positions || []).map((p) => ({
        size: toWad(p.size),
        maxPrice: toWad(p.maxPrice),
        spent: toWad(p.spent),
        tokens: toWad(p.tokens),
        status: String(p.status),
        placedBlock: String(p.placedBlock),
      })),
    })),
    graduated: Boolean(out.graduated),
    failReasons: out.failReasons || [],
    clearingPrice: toWad(out.clearingPrice),
    mcapFDV: toWad(out.mcapFDV),
    mcapCirculating: toWad(out.mcapCirculating),
    lockedTokens: toWad(out.lockedTokens),
    lpHealth: fracToWad(out.lpHealth),
    lpHealthFloor: fracToWad(out.lpHealthFloor),
    cashFloor: toWad(out.cashFloor),
    cashOverCircMcap: fracToWad(out.cashOverCircMcap),
    soldTokens: toWad(out.soldTokens),
    sidePoolTokens: toWad(out.sidePoolTokens),
    extraSoldFromReserve: toWad(out.extraSoldFromReserve),
    entryBest: entryStat(out.entryBest),
    entryMean: toWad(out.entryMean),
    entryWorst: entryStat(out.entryWorst),
  };

  return {
    schema: "stonkz-ladder-fixture/1",
    sourceSchema: raw.schema,
    sourceFile: fileName,
    generated: new Date().toISOString(),
    sourceGenerated: raw.generated,
    inputs,
    bids,
    clearingPath,
    outputs,
  };
}

function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const files = fs.readdirSync(SRC).filter((f) => f.endsWith(".json")).sort();
  if (files.length !== 10) {
    console.error(`expected 10 vector JSONs in ${SRC}, found ${files.length}`);
    process.exit(1);
  }
  const manifest = { schema: "stonkz-ladder-fixture-manifest/1", files: [] };
  for (const f of files) {
    const raw = JSON.parse(fs.readFileSync(path.join(SRC, f), "utf8"));
    const fix = convertVector(raw, f);
    const outName = f; // keep same basename
    fs.writeFileSync(path.join(OUT, outName), JSON.stringify(fix) + "\n");
    manifest.files.push({
      file: outName,
      tier: fix.inputs.tier,
      graduated: fix.outputs.graduated,
      bids: fix.bids.length,
      pathRows: fix.clearingPath.length,
    });
    console.log(`wrote fixtures/ladder/${outName} (bids=${fix.bids.length} path=${fix.clearingPath.length})`);
  }
  fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`wrote manifest (${manifest.files.length} files)`);
}

main();
