#!/usr/bin/env python3
"""Deterministic corpus generator for packages/handlebars W1/W2/W3 benchmarks."""

import json
import os
import sys


def generate(out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)

    # W1: Large e-commerce / dashboard HTML page (nested #each + #if + partials + HTML escape)
    w1_partial_badge = '<span class="badge badge-{{level}}">{{label}}</span>'
    w1_partial_card = (
        '<article class="card" data-id="{{id}}">'
        '<h3>{{name}}</h3>'
        '<p class="desc">{{description}}</p>'
        '<div class="price">${{price}} {{#if on_sale}}{{> badge level="sale" label="SALE"}}{{else}}{{> badge level="std" label="REGULAR"}}{{/if}}</div>'
        '<ul class="tags">{{#each tags}}<li>{{this}}</li>{{/each}}</ul>'
        '</article>'
    )
    w1_page = (
        '<!doctype html><html><head><title>{{store.title}}</title></head><body>'
        '<header><h1>{{store.title}}</h1><p>{{store.subtitle}}</p></header>'
        '<main>'
        '{{#each sections}}'
        '<section id="sec-{{@index}}"><h2>{{heading}}</h2>'
        '{{#if featured}}<div class="featured-banner">Featured Collection</div>{{/if}}'
        '<div class="grid">{{#each products}}{{> card}}{{/each}}</div>'
        '</section>'
        '{{/each}}'
        '</main>'
        '<footer>Total sections: {{store.section_count}}</footer>'
        '</body></html>'
    )

    sections = []
    for s in range(4):
        products = []
        for p in range(15):
            idx = s * 15 + p
            products.append(
                {
                    "id": idx + 1,
                    "name": f'Widget #{idx + 1} <Pro & "Max">',
                    "description": f"High-performance item {idx + 1} with <precision> & 'reliability' support.",
                    "price": 19 + (idx % 80),
                    "on_sale": (idx % 3 == 0),
                    "tags": [f"cat-{s}", "fast", "pure & safe" if idx % 2 == 0 else "standard"],
                }
            )
        sections.append(
            {
                "heading": f'Section {s + 1}: Top Picks & "Deals"',
                "featured": (s % 2 == 0),
                "products": products,
            }
        )
    w1_data = {
        "store": {
            "title": 'Pion Market <2026> & Co.',
            "subtitle": "Fast, safe & deterministic rendering",
            "section_count": len(sections),
        },
        "sections": sections,
    }

    with open(os.path.join(out_dir, "w1_badge.hbs"), "w", encoding="utf-8") as f:
        f.write(w1_partial_badge)
    with open(os.path.join(out_dir, "w1_card.hbs"), "w", encoding="utf-8") as f:
        f.write(w1_partial_card)
    with open(os.path.join(out_dir, "w1_page.hbs"), "w", encoding="utf-8") as f:
        f.write(w1_page)
    with open(os.path.join(out_dir, "w1_data.json"), "w", encoding="utf-8") as f:
        json.dump(w1_data, f, separators=(",", ":"))

    # W2: AI Prompt / Email template compile + render E2E (with / lookup / block params / {{~ ~}} / subexpr)
    w2_tmpl = (
        'System: {{~#with agent as |a|~}}{{a.name}} ({{a.role}}){{~/with~}}\n'
        'Priority: {{lookup priority_labels priority}}\n'
        'Tools:\n'
        '{{~#each tools as |tool idx|~}}\n'
        '  - [{{idx}}] {{tool.name}}: {{tool.desc}}{{#if (eq tool.tier "core")}} [CORE]{{/if}}\n'
        '{{~/each~}}\n'
        'User <{{user.email}}>: {{user.query}}\n'
    )
    w2_data = {
        "agent": {"name": "PionAssistant", "role": "engineer & reviewer"},
        "priority": "high",
        "priority_labels": {"low": "P3-Low", "medium": "P2-Medium", "high": "P1-High <Urgent>"},
        "tools": [
            {"name": "read_file", "desc": "Read UTF-8 file contents", "tier": "core"},
            {"name": "edit_file", "desc": "Apply targeted edits & diffs", "tier": "core"},
            {"name": "run_test", "desc": "Execute unit & integration tests", "tier": "core"},
            {"name": "web_search", "desc": "Search docs <online>", "tier": "ext"},
            {"name": "bench_run", "desc": "Run head-to-head benchmarks", "tier": "ext"},
        ],
        "user": {
            "email": "dev@example.com",
            "query": 'Please verify <Handlebars> & "Mustache" parity.',
        },
    }
    with open(os.path.join(out_dir, "w2_tmpl.hbs"), "w", encoding="utf-8") as f:
        f.write(w2_tmpl)
    with open(os.path.join(out_dir, "w2_data.json"), "w", encoding="utf-8") as f:
        json.dump(w2_data, f, separators=(",", ":"))

    # W3: Long loop + high HTML escaping density table (500 rows)
    w3_tmpl = (
        '<table><thead><tr><th>#</th><th>Key</th><th>Payload</th><th>Note</th></tr></thead><tbody>'
        '{{#each rows}}'
        '<tr><td>{{@index}}</td><td>{{key}}</td><td>{{payload}}</td><td>{{note}}</td></tr>'
        '{{/each}}'
        '</tbody></table>'
    )
    rows = []
    for i in range(500):
        rows.append(
            {
                "key": f'k_{i}_<tag>&"q"',
                "payload": f'<div class="item-{i}" data-x="a&b">val & \'quote\' < {i} ></div>',
                "note": f'row {i}: a < b && c > d && "e" & \'f\'',
            }
        )
    w3_data = {"rows": rows}
    with open(os.path.join(out_dir, "w3_tmpl.hbs"), "w", encoding="utf-8") as f:
        f.write(w3_tmpl)
    with open(os.path.join(out_dir, "w3_data.json"), "w", encoding="utf-8") as f:
        json.dump(w3_data, f, separators=(",", ":"))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: gen_data.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    generate(sys.argv[1])
