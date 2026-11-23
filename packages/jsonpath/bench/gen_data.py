#!/usr/bin/env python3
"""Deterministic corpus generator for packages/jsonpath head-to-head benchmarks."""
import json
import os
import sys


def gen_k8s_tree(num_services: int = 120) -> dict:
    namespaces = ["prod", "staging", "canary", "infra"]
    regions = ["ap-northeast-1", "us-west-2", "eu-central-1"]
    items = []
    for i in range(num_services):
        ns = namespaces[i % len(namespaces)]
        reg = regions[i % len(regions)]
        replicas = (i % 6) + 1
        containers = []
        for c in range(2 + (i % 3)):
            containers.append({
                "cpu_millis": 100 * (c + 1) + (i % 4) * 50,
                "env": [
                    {"name": "APP_ENV", "value": ns},
                    {"name": "REGION", "value": reg},
                    {"name": "SHARD", "value": f"s{i:03d}-c{c}"},
                ],
                "image": f"registry.example.com/{ns}/svc-{i % 17}:v1.{c}.{i % 9}",
                "mem_mb": 128 * (c + 1),
                "name": f"ctr-{c}-{'main' if c == 0 else 'sidecar'}",
                "ports": [8080 + c, 9090 + c],
            })
        items.append({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "labels": {
                    "app": f"svc-{i:03d}",
                    "env": ns,
                    "tier": "frontend" if i % 3 == 0 else "backend",
                },
                "name": f"deploy-{ns}-{i:03d}",
                "namespace": ns,
                "uid": f"uid-{i:06d}-{reg}",
            },
            "spec": {
                "containers": containers,
                "replicas": replicas,
                "strategy": "RollingUpdate" if i % 2 == 0 else "Recreate",
            },
            "status": {
                "availableReplicas": replicas if i % 5 != 0 else replicas - 1,
                "ready": i % 5 != 0,
                "restarts": i % 7,
            },
        })
    return {
        "apiVersion": "v1",
        "cluster": "tokyo-prod-01",
        "items": items,
        "kind": "DeploymentList",
    }


def main() -> None:
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    # W1: Large K8s tree + complex RFC 9535 queries (with $.., Filter, Slice, length(), match(), search())
    k8s = gen_k8s_tree(120)
    with open(os.path.join(out_dir, "w1_k8s.json"), "w", encoding="utf-8") as f:
        json.dump(k8s, f, sort_keys=True, separators=(",", ":"))

    w1_queries = [
        "$.items[?@.metadata.namespace == 'prod' && @.spec.replicas >= 3].metadata.name",
        "$..containers[?@.cpu_millis >= 250 && match(@.name, 'ctr-[0-9]+-sidecar')].image",
        "$.items[0:60:2].spec.containers[?length(@.name) >= 10].ports[0]",
        "$..env[?@.name == 'SHARD' && search(@.value, 'c0')].value",
        "$.items[?count(@.spec.containers[*]) >= 3 && @.status.ready == true].metadata.uid",
        "$..ports[0:2]",
    ]
    with open(os.path.join(out_dir, "w1_queries.txt"), "w", encoding="utf-8") as f:
        for q in w1_queries:
            f.write(q + "\n")

    # W2: Precompiled hot-path document + 10 queries (5,000 iters = 50,000 evals)
    w2_doc = {
        "config": {
            "features": {"alpha": True, "beta": False, "gamma": True},
            "limits": {"burst": 200, "qps": 1500, "timeout_ms": 300},
            "region": "ap-northeast-1",
            "version": 42,
        },
        "nodes": [
            {"active": i % 2 == 0, "id": i, "load": (i * 17) % 100, "name": f"node-{i:02d}", "zone": f"z{i % 3}"}
            for i in range(24)
        ],
        "service": "edge-router",
    }
    with open(os.path.join(out_dir, "w2_doc.json"), "w", encoding="utf-8") as f:
        json.dump(w2_doc, f, sort_keys=True, separators=(",", ":"))

    w2_queries = [
        "$.config.limits.qps",
        "$.config.region",
        "$.nodes[0].name",
        "$.nodes[-1].load",
        "$.nodes[2:10:2].id",
        "$.nodes[?@.active == true && @.load < 50].name",
        "$.nodes[?@.zone == 'z1'].id",
        "$.config.features.*",
        "$.nodes[?length(@.name) == 7 && @.id >= 20].load",
        "$.service",
    ]
    with open(os.path.join(out_dir, "w2_queries.txt"), "w", encoding="utf-8") as f:
        for q in w2_queries:
            f.write(q + "\n")

    # W3: 100 realistic JSON before/after/merge_patch triples (50 iters = 5,000 roundtrips)
    with open(os.path.join(out_dir, "w3_pairs.jsonl"), "w", encoding="utf-8") as f:
        for i in range(100):
            before = {
                "active": i % 2 == 0,
                "id": i,
                "meta": {"owner": f"team-{i % 5}", "rev": i, "tag": "v1"},
                "scores": [10, 20, 30 + i, 40],
                "title": f"item-{i:03d}",
            }
            after = {
                "active": i % 3 == 0,
                "id": i,
                "meta": {"owner": f"team-{(i + 1) % 5}", "rev": i + 1, "region": "tokyo"},
                "scores": [10, 25, 30 + i, 40, 50],
                "title": f"item-{i:03d}-updated",
            }
            mpatch = {
                "meta": {"rev": i + 2, "tag": None, "verified": True},
                "extra": i * 3,
            }
            rec = {"after": after, "before": before, "mpatch": mpatch}
            f.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
