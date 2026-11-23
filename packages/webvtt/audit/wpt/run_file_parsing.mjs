// Runs the vendored upstream WPT `webvtt/parsing/file-parsing` conformance suite against `packages/webvtt`.
//
//   node run_file_parsing.mjs <probe-binary> [--verbose]
//
// Every `tests/<name>.html` is executed unmodified: the assertion block between
// `var cues = video.textTracks[0].cues;` and `this.done();` is evaluated in a VM sandbox whose `cues`
// is built from `probe track support/<name>.vtt` (i.e. `webvtt::parse_lenient`, the browser-mode entry point).
// `signature-invalid.html` expects the parse to fail for each listed file.
//
// Mapping (the only glue; it mirrors what a VTTCue-consuming player must do with the public API):
//   startTime/endTime = h*3600 + m*60 + s + ms/1000 (W3C §6.3 formula) ; vertical "" | "rl" | "lr"
//   line = "auto" | number ; snapToLines = !Percentage ; lineAlign: LineAlign::Auto -> "start" (VTTCue default)
//   position = "auto" | number ; positionAlign/size/align verbatim
//   region = settings.region == "" ? null : (last region object whose id matches, else null)
//   cue list order = HTML "text track cue order" (start asc, end desc, insertion order)
//
// Exit status 0 only if every applicable test passes.
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const probe = process.argv[2];
const verbose = process.argv.includes("--verbose");
const root = join(here, "file-parsing");

// Tests that observe browser state outside the WebVTT parser output and therefore cannot apply to a library.
const NOT_APPLICABLE = {
  "stylesheets": "asserts document.styleSheets.length (page DOM), not parser output",
};

function runProbe(mode, files) {
  const out = execFileSync(probe, [mode, ...files], { maxBuffer: 1 << 28 }).toString("utf8");
  const res = new Map();
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    const j = JSON.parse(line);
    res.set(j.file, j);
  }
  return res;
}

function num(v) {
  if (v === "Infinity") return Infinity;
  if (v === "-Infinity") return -Infinity;
  if (v === "NaN") return NaN;
  return v;
}

function seconds(ms) {
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  const f = ms % 1000;
  return h * 60 * 60 + m * 60 + s + f / 1000;
}

function buildCues(track) {
  const regions = track.regions.map((r) => ({
    id: r.id,
    width: num(r.width),
    lines: r.lines,
    regionAnchorX: num(r.regionAnchorX),
    regionAnchorY: num(r.regionAnchorY),
    viewportAnchorX: num(r.viewportAnchorX),
    viewportAnchorY: num(r.viewportAnchorY),
    scroll: r.scroll,
  }));
  const cues = track.cues.map((c, idx) => {
    let region = null;
    if (c.region !== "") {
      for (const r of regions) if (r.id === c.region) region = r;
    }
    return {
      _idx: idx,
      id: c.id,
      startTime: seconds(c.start_ms),
      endTime: seconds(c.end_ms),
      pauseOnExit: false,
      text: c.text,
      vertical: c.vertical,
      snapToLines: c.snapToLines,
      line: num(c.line),
      lineAlign: c.lineAlign === "auto" ? "start" : c.lineAlign,
      position: num(c.position),
      positionAlign: c.positionAlign,
      size: num(c.size),
      align: c.align,
      region,
    };
  });
  cues.sort((a, b) => a.startTime - b.startTime || b.endTime - a.endTime || a._idx - b._idx);
  return cues;
}

class AssertionError extends Error {}
function fmt(v) {
  try {
    return typeof v === "string" ? JSON.stringify(v) : (typeof v === "object" && v !== null ? JSON.stringify(v) : String(v));
  } catch {
    return String(v);
  }
}
const asserts = {
  assert_equals(a, b, msg) {
    if (!(Object.is(a, b) || (a === b))) throw new AssertionError(`assert_equals: got ${fmt(a)}, expected ${fmt(b)}${msg ? " (" + msg + ")" : ""}`);
  },
  assert_not_equals(a, b, msg) {
    if (a === b) throw new AssertionError(`assert_not_equals: both ${fmt(a)}${msg ? " (" + msg + ")" : ""}`);
  },
  assert_true(a, msg) {
    if (a !== true) throw new AssertionError(`assert_true: got ${fmt(a)}${msg ? " (" + msg + ")" : ""}`);
  },
  assert_false(a, msg) {
    if (a !== false) throw new AssertionError(`assert_false: got ${fmt(a)}${msg ? " (" + msg + ")" : ""}`);
  },
  assert_unreached(msg) {
    throw new AssertionError(`assert_unreached: ${msg}`);
  },
};

const results = [];
const testsDir = join(root, "tests");
const names = readdirSync(testsDir).filter((f) => f.endsWith(".html")).map((f) => f.slice(0, -5)).sort();
const vtts = names.map((n) => join(testsDir, "support", n + ".vtt"));
const parsed = runProbe("track", vtts);

for (const name of names) {
  if (NOT_APPLICABLE[name]) {
    results.push({ name, status: "N/A", detail: NOT_APPLICABLE[name] });
    continue;
  }
  const html = readFileSync(join(testsDir, name + ".html"), "utf8");
  const track = parsed.get(join(testsDir, "support", name + ".vtt"));
  if (!track.ok) {
    results.push({ name, status: "FAIL", detail: `track failed to load: ${track.err}` });
    continue;
  }
  const cues = buildCues(track);
  let body;
  const m = html.match(/var cues = video\.textTracks\[0\]\.cues;\n    \{\n([\s\S]*?)\n    \}\n    this\.done\(\);/);
  if (m) {
    body = m[1];
  } else if (name === "header-regions") {
    // Custom harness: keep the page's own helpers verbatim, replace only the <video>/<track> loading.
    const script = html.match(/<script>\n([\s\S]*?)<\/script>/)[1];
    body = script.slice(0, script.indexOf("async_test(")) + "\nassert_equals(cues.length, 10);\ncheckCueRegions(cues);\n";
  } else {
    results.push({ name, status: "FAIL", detail: "harness could not extract assertions" });
    continue;
  }
  const ctx = vm.createContext({ ...asserts, cues, Array, JSON, Object, Math, Number, String });
  try {
    vm.runInContext(body, ctx, { filename: name + ".html" });
    results.push({ name, status: "PASS" });
  } catch (e) {
    results.push({ name, status: "FAIL", detail: e.message });
  }
}

// signature-invalid.html: every listed file must fail to load.
{
  const html = readFileSync(join(root, "signature-invalid.html"), "utf8");
  const pairs = [...html.matchAll(/\['([^']+)',\s*'([^']+)'\]/g)].map((x) => [x[1], x[2]]);
  const files = pairs.map(([, f]) => join(root, "support", f));
  const res = runProbe("track", files);
  for (const [label, f] of pairs) {
    const r = res.get(join(root, "support", f));
    const name = `signature-invalid: ${label} (${f})`;
    if (r && !r.ok) results.push({ name, status: "PASS" });
    else results.push({ name, status: "FAIL", detail: `expected load failure, parsed ${r ? r.cues.length : "?"} cue(s)` });
  }
}

let pass = 0, fail = 0, na = 0;
for (const r of results) {
  if (r.status === "PASS") pass++;
  else if (r.status === "FAIL") fail++;
  else na++;
  if (r.status !== "PASS" || verbose) console.log(`${r.status.padEnd(4)} ${r.name}${r.detail ? "  -- " + r.detail : ""}`);
}
console.log(`WPT file-parsing: ${pass} pass, ${fail} fail, ${na} n/a (of ${results.length})`);
console.log(fail === 0 ? "RESULT: PASS" : "RESULT: FAIL");
process.exit(fail === 0 ? 0 : 1);
