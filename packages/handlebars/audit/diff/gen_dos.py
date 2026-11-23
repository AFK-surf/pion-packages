"""DoS / stack / algorithmic-complexity probes. Each case runs in its own process (per engine, per mode)
under a wall-clock budget; see dos.py for the verdict rules.

Fields beyond the probe protocol:
  budget_s  wall-clock budget for the Pion native release build (other modes get 4x)
  expect    {"out_len": n} (must render exactly n bytes) or {"err": [ErrorKind...]} (must fail with one of
            them) or {"any": true} (either, as long as it neither crashes nor exceeds the budget; used where
            Pion may legitimately render a missing @partial-block as empty instead of failing)
  finding   the REPORT.md finding id this probe demonstrates, "" for a control
  modes     restrict the Pion modes (default: all four) for probes that are slow by design
"""
import json

BIG = 2147483647  # "limits lifted"


def C(id, tmpl, data, expect, budget_s=10, partials=None, limits=None, finding="", note="", modes=None):
    c = {"id": id, "tmpl": tmpl, "data": data if isinstance(data, str) else json.dumps(data),
         "expect": expect, "budget_s": budget_s, "finding": finding, "note": note}
    if modes:
        c["modes"] = modes
    if partials:
        c["partials"] = partials
    if limits:
        c["limits"] = limits
    return c


def cases():
    out = []
    # --- recursion through partials ---------------------------------------------------------------
    out.append(C("dos/partial_block_self", "{{#> layout}}{{> @partial-block}}{{/layout}}", {},
                 {"any": True},
                 partials={"layout": "{{> @partial-block}}"}, finding="P0-1",
                 note="@partial-block inside the partial-block body re-enters itself with no depth accounting"))
    out.append(C("dos/partial_block_self_tiny_limits", "{{#> layout}}{{> @partial-block}}{{/layout}}", {},
                 {"any": True},
                 partials={"layout": "x{{> @partial-block}}"}, finding="P0-1",
                 limits={"max_depth": 8, "max_partial_depth": 4, "max_steps": 1000, "max_output_bytes": 4096},
                 note="even the tightest documented 'untrusted template' limits do not stop it"))
    out.append(C("dos/partial_block_inline_layout",
                 "{{#*inline \"l\"}}<{{> @partial-block}}>{{/inline}}{{#> l}}{{> @partial-block}}{{/l}}", {},
                 {"any": True},
                 finding="P0-1", note="same, with no registered partial at all: a single untrusted template string"))
    out.append(C("dos/partial_self", "{{> self}}", {}, {"err": ["PartialDepthLimitExceeded"]},
                 partials={"self": "x{{> self}}"}))
    out.append(C("dos/partial_cycle_ab", "{{> a}}", {}, {"err": ["PartialDepthLimitExceeded"]},
                 partials={"a": "{{> b}}", "b": "{{> a}}"}))
    out.append(C("dos/inline_self", "{{#*inline \"p\"}}{{> p}}{{/inline}}{{> p}}", {},
                 {"err": ["PartialDepthLimitExceeded"]}))
    # 2^k output amplification through a k-deep chain of partials each calling the next one twice
    def chain(k):
        ps = {"p%d" % i: "{{> p%d}}{{> p%d}}" % (i + 1, i + 1) for i in range(k)}
        ps["p%d" % k] = "x"
        return ps
    out.append(C("dos/partial_bomb_2^20", "{{> p0}}", {}, {"out_len": 1 << 20}, partials=chain(20)))
    out.append(C("dos/partial_bomb_2^30", "{{> p0}}", {}, {"err": ["StepLimitExceeded", "OutputLimitExceeded"]},
                 partials=chain(30)))
    # standalone-indented chain: every level re-buffers and re-indents the whole inner output
    ind = {"q%d" % i: "  {{> q%d}}\n" % (i + 1) for i in range(31)}
    ind["q31"] = "{{#each a}}xxxxxxxxxxxxxxx\n{{/each}}"
    out.append(C("dos/indent_chain_31x", "{{> q0}}", {"a": list(range(20000))}, {"any": True}, partials=ind))
    # --- deep nesting ------------------------------------------------------------------------------
    # the deepest nesting the default limits allow must render in every mode (Wasm32 has the smallest stack)
    out.append(C("dos/legal_if63", "{{#if x}}" * 63 + "y" + "{{/if}}" * 63, {"x": 1}, {"out_len": 1}))
    out.append(C("dos/legal_subexpr63", "{{echo " + "(echo " * 63 + "x" + ")" * 63 + "}}", {"x": 1}, {"out_len": 1}))
    deep = {"p%d" % i: "{{> p%d}}" % (i + 1) for i in range(31)}
    deep["p31"] = "{{#if x}}" * 60 + "{{echo " + "(echo " * 63 + "x" + ")" * 63 + "}}" + "{{/if}}" * 60
    out.append(C("dos/legal_partial31_if60_subexpr63", "{{> p0}}", {"x": 1}, {"out_len": 1}, partials=deep))
    out.append(C("dos/legal_each63", "{{#each a}}" * 63 + "{{this}}" + "{{/each}}" * 63, {"a": [[1]]}, {"out_len": 1}))
    for n in (1000, 10000):
        nest = "{{#if x}}" * n + "y" + "{{/if}}" * n
        out.append(C("dos/nested_if_%d_default" % n, nest, {"x": 1}, {"err": ["DepthLimitExceeded"]}))
        sub = "{{echo " + "(echo " * n + "x" + ")" * n + "}}"
        out.append(C("dos/nested_subexpr_%d_default" % n, sub, {"x": 1}, {"err": ["DepthLimitExceeded"]}))
        out.append(C("dos/else_if_chain_%d_default" % n,
                     "{{#if a}}A" + "{{else if b}}B" * n + "{{else}}E{{/if}}", {}, {"err": ["DepthLimitExceeded"]}))
    for n in (1000, 10000, 100000):
        lifted = {"max_depth": BIG}
        out.append(C("dos/nested_if_%d_lifted" % n, "{{#if x}}" * n + "y" + "{{/if}}" * n, {"x": 1},
                     {"any": True}, limits=lifted, finding="P2-7",
                     note="max_depth raised by the embedder: recursion is then bounded only by the machine stack; "
                          "rendering or a DepthLimitExceeded from an internal ceiling both pass, a crash does not"))
        out.append(C("dos/nested_subexpr_%d_lifted" % n, "{{echo " + "(echo " * n + "x" + ")" * n + "}}", {"x": 1},
                     {"any": True}, limits=lifted, finding="P2-7"))
    for n in (1000, 100000):
        out.append(C("dos/partial_self_partial_depth_%d" % n, "{{> self}}", {}, {"any": True}, partials={"self": "x{{> self}}"},
                     limits={"max_partial_depth": n}, finding="P2-7"))
    # --- wide objects: O(N*K) lookups, invisible to max_steps -----------------------------------------
    for k in (10000, 100000):
        root = {"title": "T"}
        root.update({"k%d" % i: i for i in range(k)})
        root["rows"] = list(range(k))
        out.append(C("dos/wide_root_lookup_%dx%d" % (k, k), "{{#each rows}}{{@root.title}}{{/each}}", root,
                     {"out_len": k}, budget_s=5, finding="P1-5" if k >= 100000 else "",
                     modes=["native_rel", "wasm_rel"] if k >= 100000 else None,
                     note="benign template, attacker-sized data: each @root.title scans every key of root"))
    k = 20000
    o = {"k%d" % i: i for i in range(k)}
    out.append(C("dos/wide_each_lookup_%d" % k, "{{#each o}}{{lookup ../o @key}}{{/each}}", {"o": o},
                 {"any": True}, budget_s=5, note="O(K^2) = 4e8 key compares, under budget at this size"))
    # --- limits set to 0 / negative must fail closed --------------------------------------------------
    for name, lim, kinds in (
        ("max_output_bytes=0", {"max_output_bytes": 0}, ["OutputLimitExceeded"]),
        ("max_output_bytes=-1", {"max_output_bytes": -1}, ["OutputLimitExceeded"]),
        ("max_steps=0", {"max_steps": 0}, ["StepLimitExceeded"]),
        ("max_steps=-1", {"max_steps": -1}, ["StepLimitExceeded"]),
        ("max_template_bytes=-1", {"max_template_bytes": -1}, ["TemplateSizeLimitExceeded"]),
        ("max_depth=-1", {"max_depth": -1}, ["DepthLimitExceeded"]),
        ("max_partial_depth=0", {"max_partial_depth": 0}, ["PartialDepthLimitExceeded"]),
    ):
        out.append(C("dos/limit_%s" % name, "a{{x}}{{> p}}", {"x": "b"}, {"err": kinds}, partials={"p": "c"},
                     limits=lim))
    # --- large-but-legal inputs -----------------------------------------------------------------------
    out.append(C("dos/template_4MiB_tags", "{{x}}" * (4194304 // 5), {"x": "y"}, {"out_len": 4194304 // 5}))
    out.append(C("dos/template_4MiB+1", "x" * 4194305, {}, {"err": ["TemplateSizeLimitExceeded"]}))
    out.append(C("dos/output_16MiB+1", "{{#each a}}{{s}}{{/each}}", {"a": list(range(17)), "s": "x" * 1048576},
                 {"err": ["OutputLimitExceeded"]}))
    out.append(C("dos/escape_amplification", "{{s}}", {"s": "\"" * 3355444}, {"err": ["OutputLimitExceeded"]},
                 note="6x escape expansion is accounted before writing"))
    return out


if __name__ == "__main__":
    import sys
    with open(sys.argv[1], "w", encoding="utf-8") as f:
        for c in cases():
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
