"""Turn the official Mustache Spec v1.4.2 core vectors (comments, delimiters, interpolation, inverted,
partials, sections; the optional ~lambdas/~inheritance/~dynamic-names modules are out of scope for the
package) into audit cases whose expectation is the spec's `expected` string."""
import json
import os

# Spec vectors that fail on 4ab06f4 and the REPORT.md finding each one belongs to.
FINDINGS = {
    "spec/partials/Standalone Indentation": "P2-1",
    "spec/sections/Variable test": "P1-4",
    "spec/sections/Deeply Nested Contexts": "P1-4",
}

CORE = ["comments", "delimiters", "interpolation", "inverted", "partials", "sections"]


def load(spec_dir):
    cases = []
    for mod in CORE:
        with open(os.path.join(spec_dir, mod + ".json"), encoding="utf-8") as f:
            doc = json.load(f)
        for t in doc["tests"]:
            cases.append({
                "id": "spec/%s/%s" % (mod, t["name"]),
                "tmpl": t["template"],
                "data": json.dumps(t["data"], ensure_ascii=False),
                "partials": t.get("partials", {}),
                "expect": {"out": t["expected"]},
                "ref": "Mustache Spec v1.4.2 %s.yml" % mod,
            })
            cases[-1]["finding"] = FINDINGS.get(cases[-1]["id"], "")
    return cases
