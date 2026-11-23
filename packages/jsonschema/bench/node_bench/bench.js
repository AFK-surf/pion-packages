"use strict";
const fs = require("node:fs");
const Ajv2020 = require("ajv/dist/2020");

function fnv1aStep(h, b) {
  return (Math.imul(h ^ b, 16777619) >>> 0);
}

function runBatch(schemaPath, jsonlPath, iters) {
  const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  const lines = fs
    .readFileSync(jsonlPath, "utf8")
    .split("\n")
    .filter((l) => l.length > 0);
  const instances = lines.map((l) => JSON.parse(l));

  const ajv = new Ajv2020({ strict: false });
  const validate = ajv.compile(schema);

  let valid = 0;
  let invalid = 0;
  let checksum = 2166136261 >>> 0;
  for (let it = 0; it < iters; it++) {
    for (let j = 0; j < instances.length; j++) {
      if (validate(instances[j])) {
        valid++;
        checksum = fnv1aStep(checksum, 1);
      } else {
        invalid++;
        checksum = fnv1aStep(checksum, 0);
      }
    }
  }
  process.stdout.write(`valid=${valid} invalid=${invalid} checksum=${checksum}\n`);
}

function runE2e(pairsPath, iters) {
  const lines = fs
    .readFileSync(pairsPath, "utf8")
    .split("\n")
    .filter((l) => l.length > 0);
  const pairs = lines.map((l) => JSON.parse(l));

  const ajv = new Ajv2020({ strict: false });
  let compiled = 0;
  let valid = 0;
  let invalid = 0;
  let checksum = 2166136261 >>> 0;
  for (let it = 0; it < iters; it++) {
    for (let j = 0; j < pairs.length; j++) {
      const validate = ajv.compile(pairs[j].schema);
      compiled++;
      if (validate(pairs[j].instance)) {
        valid++;
        checksum = fnv1aStep(checksum, 1);
      } else {
        invalid++;
        checksum = fnv1aStep(checksum, 0);
      }
    }
  }
  process.stdout.write(
    `compiled=${compiled} valid=${valid} invalid=${invalid} checksum=${checksum}\n`
  );
}

const args = process.argv.slice(2);
if (args.length < 3) {
  process.stderr.write("usage: bench.js batch <schema> <jsonl> <iters> | e2e <pairs> <iters>\n");
  process.exit(1);
}
if (args[0] === "batch") {
  runBatch(args[1], args[2], parseInt(args[3], 10) || 1);
} else if (args[0] === "e2e") {
  runE2e(args[1], parseInt(args[2], 10) || 1);
} else {
  process.stderr.write(`unknown mode: ${args[0]}\n`);
  process.exit(1);
}
