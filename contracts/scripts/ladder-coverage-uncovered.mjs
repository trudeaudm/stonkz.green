import fs from "node:fs";

const t = fs.readFileSync("lcov.info", "utf8");
const files = [
  "src/ladder/StonkzLadderAuction.sol",
  "src/ladder/LadderSettlement.sol",
  "src/ladder/StonkzLadderFactory.sol",
  "src/ladder/LadderMath.sol",
  "src/ladder/LadderConstants.sol",
];

for (const f of files) {
  const idx = t.indexOf(`SF:${f}`);
  // Windows paths may use backslash or absolute
  let block = null;
  const markers = [`SF:${f}`, `SF:${f.replace(/\//g, "\\")}`];
  for (const m of markers) {
    const i = t.indexOf(m);
    if (i >= 0) {
      const end = t.indexOf("end_of_record", i);
      block = t.slice(i, end);
      break;
    }
  }
  if (!block) {
    // fuzzy: find SF line containing filename
    const re = new RegExp(`SF:([^\\n]*${f.replace(/\//g, "[/\\\\]")}[^\\n]*)\\r?\\n([\\s\\S]*?)end_of_record`);
    const m = t.match(re);
    if (!m) {
      console.log(`${f}: NOT FOUND`);
      continue;
    }
    block = m[0];
  }
  const uncovered = [];
  for (const line of block.split(/\r?\n/)) {
    if (line.startsWith("DA:")) {
      const [n, c] = line.slice(3).split(",");
      if (c === "0") uncovered.push(n);
    }
  }
  console.log(`\n${f} uncovered (${uncovered.length}):`);
  console.log(uncovered.length ? uncovered.join(", ") : "(none)");
}
