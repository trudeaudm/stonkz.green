#!/usr/bin/env node
/**
 * vanity-mine.mjs — grind userSalt so CREATE2 address top two bytes == 0x4663
 *
 * Exact init-code hash MUST include constructor args (factory stamps applied).
 * Prefer factory.listingInitCodeHash / auctionInitCodeHash on-chain, then:
 *
 *   node contracts/scripts/vanity-mine.mjs \
 *     --factory 0x... --deployer 0x... --initCodeHash 0x...
 *
 * Output: userSalt + predicted address (JSON).
 *
 * Also supports protocol-token CREATE2 from an EOA deployer:
 *   node contracts/scripts/vanity-mine.mjs --mode eoa --deployer 0x... --initCodeHash 0x...
 *
 * Deep prefix 0x46634663 remains OPEN (genesis-flex) — this miner targets 0x4663 only.
 */
"use strict";

const { keccak256, encodePacked, encodeAbiParameters, parseAbiParameters } = require("viem");
// Prefer built-in crypto if viem not installed — pure JS fallback below.

const PREFIX = 0x4663n;
const MAX = 1_000_000n;

function parseArgs(argv) {
  const out = { mode: "factory" };
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

/** Minimal keccak256 via Node crypto (no viem required). */
function keccak(buf) {
  return "0x" + require("crypto").createHash("sha3-256").update(buf).digest("hex");
}

// Ethereum uses Keccak-256 (not NIST SHA3). Use keccak from 'ethereum-cryptography' or viem.
// Fallback: try to load viem; else @noble/hashes; else tell user to install.
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

/** abi.encode(address, bytes32) */
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

function mine({ mode, factory, deployer, initCodeHash, max = MAX }) {
  const deploySite = mode === "eoa" ? deployer : factory;
  if (!deploySite) throw new Error(mode === "eoa" ? "--deployer required" : "--factory required");
  if (!deployer) throw new Error("--deployer required");
  if (!initCodeHash) throw new Error("--initCodeHash required");

  const ich = normalizeHex(initCodeHash);
  for (let i = 0n; i < max; i++) {
    const userSalt = "0x" + i.toString(16).padStart(64, "0");
    let salt = userSalt;
    if (mode !== "eoa") {
      // salt = keccak256(abi.encode(deployer, userSalt))
      salt = ethKeccak256(abiEncodeAddressBytes32(deployer, userSalt));
    }
    const predicted = create2Address(deploySite, salt, ich);
    if (prefixOf(predicted) === PREFIX) {
      return { userSalt, salt, predicted, attempts: Number(i + 1n), mode, prefix: "0x4663" };
    }
  }
  throw new Error(`no vanity salt in ${max} attempts`);
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log(`Usage:
  node vanity-mine.mjs --factory 0xF --deployer 0xD --initCodeHash 0xH
  node vanity-mine.mjs --mode eoa --deployer 0xD --initCodeHash 0xH`);
    process.exit(0);
  }
  const result = mine(args);
  console.log(JSON.stringify(result, null, 2));
}

main();
