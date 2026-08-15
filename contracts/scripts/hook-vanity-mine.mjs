#!/usr/bin/env node
/**
 * hook-vanity-mine.mjs — grind CREATE2 salt for StonkzFeeHook:
 *   top two bytes == 0x4663 AND low 14 bits == 0x088
 *   (BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA)
 *
 * Expected ~2^30 attempts. Port of launch-deploy vanity-mine + hook flags (V4-CANON Phase 1).
 *
 * Usage (forge script salted `new` — CREATE2 site is Foundry CREATE2_FACTORY, salt as-is):
 *   node contracts/scripts/hook-vanity-mine.mjs \
 *     --mode eoa --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C --initCodeHash 0x...
 * Usage (Stonkz factory CREATE2 — salt = keccak256(deployer, userSalt)):
 *   node contracts/scripts/hook-vanity-mine.mjs \
 *     --mode factory --factory 0x... --deployer 0x... --initCodeHash 0x...
 *
 * Output: JSON { salt, userSalt, predicted, attempts, prefix, flags }
 *
 * Dep: @noble/hashes v2 (ESM) — import from `@noble/hashes/sha3.js`
 * (install: npm i in contracts/scripts/).
 */
import { keccak_256 } from "@noble/hashes/sha3.js";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";
import { cpus } from "node:os";
import { fileURLToPath } from "node:url";

const PREFIX = 0x4663n;
/** BEFORE_SWAP (1<<7) | BEFORE_SWAP_RETURNS_DELTA (1<<3) = 0x88 */
const HOOK_FLAGS = 0x088n;
const ALL_HOOK_MASK = (1n << 14n) - 1n;
const MAX = 1n << 32n; // hard stop; expected hit well before
const SELF = fileURLToPath(import.meta.url);

function parseArgs(argv) {
  const out = { mode: "eoa" };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mode") out.mode = argv[++i];
    else if (a === "--factory") out.factory = argv[++i];
    else if (a === "--deployer") out.deployer = argv[++i];
    else if (a === "--initCodeHash") out.initCodeHash = argv[++i];
    else if (a === "--max") out.max = BigInt(argv[++i]);
    else if (a === "--help") out.help = true;
  }
  return out;
}

function normalizeHex(h) {
  if (!h) throw new Error("missing hex");
  return h.startsWith("0x") || h.startsWith("0X") ? h.toLowerCase() : `0x${h.toLowerCase()}`;
}

/** Ethereum Keccak-256 (not NIST SHA3). @noble/hashes v2: subpath is sha3.js */
function ethKeccak256(data) {
  const bytes = typeof data === "string" ? Buffer.from(data.slice(2), "hex") : data;
  return "0x" + Buffer.from(keccak_256(bytes)).toString("hex");
}

function pad32(hexOrBig) {
  if (typeof hexOrBig === "bigint") {
    return Buffer.from(hexOrBig.toString(16).padStart(64, "0"), "hex");
  }
  const h = normalizeHex(hexOrBig).slice(2);
  return Buffer.from(h.padStart(64, "0"), "hex");
}

function addrBuf(a) {
  const h = normalizeHex(a).slice(2);
  if (h.length !== 40) throw new Error(`bad address ${a}`);
  return Buffer.from(h, "hex");
}

function abiEncodeAddressBytes32(addr, bytes32hex) {
  return Buffer.concat([pad32(BigInt(normalizeHex(addr))), pad32(bytes32hex)]);
}

function create2Address(deployer, salt, initCodeHash) {
  const buf = Buffer.concat([
    Buffer.from([0xff]),
    addrBuf(deployer),
    pad32(salt),
    pad32(initCodeHash),
  ]);
  const hash = ethKeccak256(buf);
  return "0x" + hash.slice(-40);
}

function prefixOf(addr) {
  return BigInt("0x" + normalizeHex(addr).slice(2, 6));
}

function flagsOf(addr) {
  return BigInt(normalizeHex(addr)) & ALL_HOOK_MASK;
}

function matchesAddr(addr) {
  return prefixOf(addr) === PREFIX && flagsOf(addr) === HOOK_FLAGS;
}

/** Search [start, end) on one thread. Returns hit object or null. */
function mineEoaRange(deploySite, ich, startI, endI, progressEveryMs = 0) {
  const buf = Buffer.alloc(85); // 0xff || deployer(20) || salt(32) || initCodeHash(32)
  buf[0] = 0xff;
  addrBuf(deploySite).copy(buf, 1);
  pad32(ich).copy(buf, 53);

  const t0 = Date.now();
  let lastLog = t0;
  for (let i = startI; i < endI; i++) {
    buf[49] = (i >>> 24) & 0xff;
    buf[50] = (i >>> 16) & 0xff;
    buf[51] = (i >>> 8) & 0xff;
    buf[52] = i & 0xff;

    const hash = keccak_256(buf);
    if (hash[12] === 0x46 && hash[13] === 0x63) {
      const flags = ((hash[30] & 0x3f) << 8) | hash[31];
      if (flags === 0x088) {
        const predicted = "0x" + Buffer.from(hash.subarray(12, 32)).toString("hex");
        const salt = "0x" + i.toString(16).padStart(64, "0");
        return {
          userSalt: salt,
          salt,
          predicted,
          attempts: i + 1, // 1-based index of winning salt (same as sequential miner)
          mode: "eoa",
          prefix: "0x4663",
          flags: "0x088",
        };
      }
    }

    if (progressEveryMs > 0 && Date.now() - lastLog > progressEveryMs) {
      const done = i - startI;
      const rate = done / ((Date.now() - t0) / 1000);
      parentPort?.postMessage({ type: "progress", i, rate });
      lastLog = Date.now();
    }
  }
  return null;
}

function mineFactory({ factory, deployer, initCodeHash, max = MAX }) {
  const deploySite = factory;
  if (!deploySite) throw new Error("--factory required");
  if (!deployer) throw new Error("--deployer required");
  if (!initCodeHash) throw new Error("--initCodeHash required");

  const ich = normalizeHex(initCodeHash);
  const start = Date.now();
  let lastLog = start;
  for (let i = 0n; i < max; i++) {
    const userSalt = "0x" + i.toString(16).padStart(64, "0");
    const salt = ethKeccak256(abiEncodeAddressBytes32(deployer, userSalt));
    const predicted = create2Address(deploySite, salt, ich);
    if (matchesAddr(predicted)) {
      return {
        userSalt,
        salt,
        predicted,
        attempts: Number(i + 1n),
        mode: "factory",
        prefix: "0x4663",
        flags: "0x088",
        elapsedMs: Date.now() - start,
      };
    }
    if (Date.now() - lastLog > 5000) {
      const rate = Number(i) / ((Date.now() - start) / 1000);
      process.stderr.write(`… ${i} attempts (~${rate.toFixed(0)}/s)\n`);
      lastLog = Date.now();
    }
  }
  throw new Error(`no salt in ${max} attempts`);
}

async function mineEoaParallel({ deployer, initCodeHash, max = MAX }) {
  if (!deployer) throw new Error("--deployer required");
  if (!initCodeHash) throw new Error("--initCodeHash required");
  const ich = normalizeHex(initCodeHash);
  const maxN = max > 0xffffffffn ? 0x100000000 : Number(max);
  const nWorkers = Math.max(1, cpus().length);
  const chunk = Math.ceil(maxN / nWorkers);
  const start = Date.now();

  process.stderr.write(`mining eoa with ${nWorkers} workers over [0, ${maxN})\n`);

  return new Promise((resolve, reject) => {
    const workers = [];
    let settled = false;
    let doneCount = 0;

    const finish = (err, result) => {
      if (settled) return;
      settled = true;
      for (const w of workers) {
        w.terminate().catch(() => {});
      }
      if (err) reject(err);
      else resolve({ ...result, elapsedMs: Date.now() - start });
    };

    for (let w = 0; w < nWorkers; w++) {
      const startI = w * chunk;
      const endI = Math.min(maxN, startI + chunk);
      if (startI >= endI) break;
      const worker = new Worker(SELF, {
        workerData: { deployer, ich, startI, endI },
      });
      workers.push(worker);
      worker.on("message", (msg) => {
        if (msg?.type === "progress") {
          process.stderr.write(`… worker@${msg.i} (~${msg.rate.toFixed(0)}/s local)\n`);
        } else if (msg?.type === "hit") {
          finish(null, msg.result);
        } else if (msg?.type === "done") {
          doneCount++;
          if (!settled && doneCount === workers.length) {
            finish(new Error(`no salt in ${max} attempts`));
          }
        }
      });
      worker.on("error", (e) => finish(e));
    }
  });
}

if (!isMainThread) {
  const { deployer, ich, startI, endI } = workerData;
  const hit = mineEoaRange(deployer, ich, startI, endI, 5000);
  if (hit) parentPort.postMessage({ type: "hit", result: hit });
  else parentPort.postMessage({ type: "done" });
} else {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log(
      `Usage: node hook-vanity-mine.mjs --mode eoa|factory --deployer 0x... --initCodeHash 0x... [--factory 0x...]`
    );
    process.exit(0);
  }
  try {
    const result =
      args.mode === "eoa"
        ? await mineEoaParallel(args)
        : mineFactory(args);
    console.log(JSON.stringify(result, null, 2));
  } catch (e) {
    console.error(String(e.message || e));
    process.exit(1);
  }
}
