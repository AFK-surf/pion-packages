"""Blind-spot workloads the official W1/W2/W3 do not cover (written to <out_dir>):
  B1 wide-object lookups   2,000 rows x `{{@root.title}}`, root object with 5,000 extra keys
  B2 partial fan-out       a 12-level partial tree, 4,096 leaf partial renders per page (high reuse)
  B3 large-template compile  ~64 KiB template compiled + rendered from source every iteration
All three render byte-identical output in Pion and in Rust `handlebars` (only @root paths, no Mustache
context bubbling, integers only)."""
import json
import os
import sys


def main(out):
    os.makedirs(out, exist_ok=True)
    root = {"title": "T&C"}
    root.update({"k%05d" % i: i for i in range(5000)})
    root["rows"] = list(range(2000))
    with open(os.path.join(out, "b1_data.json"), "w") as f:
        json.dump(root, f, separators=(",", ":"))
    with open(os.path.join(out, "b1_tmpl.hbs"), "w") as f:
        f.write("{{#each rows}}<i>{{@root.title}}{{this}}</i>{{/each}}")
    for i in range(12):
        with open(os.path.join(out, "b2_p%d.hbs" % i), "w") as f:
            f.write("<s>{{> p%d}}{{> p%d}}</s>" % (i + 1, i + 1))
    with open(os.path.join(out, "b2_p12.hbs"), "w") as f:
        f.write("{{name}}")
    with open(os.path.join(out, "b2_data.json"), "w") as f:
        json.dump({"name": "x&y"}, f)
    unit = "<div id=\"{{id}}\">{{#each items}}<p>{{name}} {{#if flag}}Y{{else}}N{{/if}}</p>{{/each}}</div>\n"
    with open(os.path.join(out, "b3_tmpl.hbs"), "w") as f:
        f.write(unit * (65536 // len(unit)))
    with open(os.path.join(out, "b3_data.json"), "w") as f:
        json.dump({"id": 7, "items": [{"name": "a<b", "flag": True}, {"name": "c", "flag": False}]}, f)


if __name__ == "__main__":
    main(sys.argv[1])
