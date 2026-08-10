#!/usr/bin/env node
/**
 * hook-vanity-mine.mjs — grind CREATE2 salt for StonkzFeeHook:
 *   top two bytes == 0x4663 AND low 14 bits == 0x088
 *   (BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA)
 *
 * Expected ~2^30 attempts. Port of launch-deploy vanity-mine + hook flags (V4-CANON Phase 1).
 *
 * Usage:
 *   node contracts/scripts/hook-vanity-mine.mjs \
 *     --mode eoa --deployer 0x... --initCodeHash 0x...
 *   node contracts/scripts/hook-vanity-mine.mjs \
 *     --mode factory --factory 0x... --deployer 0x... --initCodeHash 0x...
 *
 * Output: JSON { salt, userSalt, predicted, attempts, prefix, flags }
 */
"use strict";

const PREFIX = 0x4663n;
/** BEFORE_SWAP (1<<7) | BEFORE_SWAP_RETURNS_DELTA (1<<3) = 0x88 */
const HOOK_FLAGS = 0x088n;
const ALL_HOOK_MASK = (1n << 14n) - 1n;
const MAX = 1n << 32n; // hard stop; expected hit well before

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

function ethKeccak256(data) {
  try {
    const { keccak_256 } = require("@noble/hashes/sha3");
    const bytes = typeof data === "string" ? Buffer.from(data.slice(2), "hex") : data;
    return "0x" + Buffer.from(keccak_256(bytes)).toString("hex");
  } catch {
    try {
      const { keccak256: k } = require("viem");
      return k(data);
    } catch {
      console.error("Install @noble/hashes or viem: npm i @noble/hashes");
      process.exit(1);
    }
  }
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

function mine({ mode, factory, deployer, initCodeHash, max = MAX }) {
  const deploySite = mode === "eoa" ? deployer : factory;
  if (!deploySite) throw new Error(mode === "eoa" ? "--deployer required" : "--factory required");
  if (!deployer) throw new Error("--deployer required");
  if (!initCodeHash) throw new Error("--initCodeHash required");

  const ich = normalizeHex(initCodeHash);
  const start = Date.now();
  let lastLog = start;
  for (let i = 0n; i < max; i++) {
    const userSalt = "0x" + i.toString(16).padStart(64, "0");
    let salt = userSalt;
    if (mode !== "eoa") {
      salt = ethKeccak256(abiEncodeAddressBytes32(deployer, userSalt));
    }
    const predicted = create2Address(deploySite, salt, ich);
    if (matchesAddr(predicted)) {
      return {
        userSalt,
        salt,
        predicted,
        attempts: Number(i + 1n),
        mode,
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

const args = parseArgs(process.argv);
if (args.help) {
  console.log(`Usage: node hook-vanity-mine.mjs --mode eoa|factory --deployer 0x... --initCodeHash 0x... [--factory 0x...]`);
  process.exit(0);
}
try {
  const result = mine(args);
  console.log(JSON.stringify(result, null, 2));
} catch (e) {
  console.error(String(e.message || e));
  process.exit(1);
}
