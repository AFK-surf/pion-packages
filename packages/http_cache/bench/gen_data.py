#!/usr/bin/env python3
"""Generate realistic YouTube / Twitter(X) / CDN / API HTTP caching benchmark corpus."""
import os
import sys

T0 = 1700000000  # Tue, 14 Nov 2023 22:13:20 GMT

CASES = [
    # 1. YouTube static JS bundle (shared CDN, public, immutable, Vary: Accept-Encoding)
    {
        "id": "yt_static_js",
        "method": "GET",
        "uri": "https://www.youtube.com/s/desktop/a1b2c3d4/jsbin/desktop_polymer.vflset/desktop_polymer.js",
        "shared": 1,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 120,
        "status": 200,
        "req_h": [("accept-encoding", "gzip, deflate, br"), ("user-agent", "PionBrowser/1.0")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "public, max-age=31536000, immutable"),
            ("vary", "Accept-Encoding"),
            ("etag", '"yt-poly-991"'),
            ("content-type", "text/javascript; charset=utf-8"),
        ],
        "lookup_req_h": [("accept-encoding", "gzip, deflate, br")],
        "reval_304_h": [],
    },
    # 2. YouTube watch page (private, no-cache -> needs revalidation with ETag + 304 refresh)
    {
        "id": "yt_watch_html",
        "method": "GET",
        "uri": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "shared": 0,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 15,
        "status": 200,
        "req_h": [("accept-encoding", "br"), ("accept-language", "en-US")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "private, no-cache"),
            ("vary", "Accept-Encoding, Accept-Language"),
            ("etag", '"watch-v42"'),
            ("last-modified", "Tue, 14 Nov 2023 21:00:00 GMT"),
        ],
        "lookup_req_h": [("accept-encoding", "br"), ("accept-language", "en-US")],
        "reval_304_h": [
            ("date", "Tue, 14 Nov 2023 22:13:35 GMT"),
            ("cache-control", "private, max-age=120"),
            ("etag", '"watch-v42"'),
        ],
    },
    # 3. YouTube videoplayback CDN segment (s-maxage > max-age, Age header)
    {
        "id": "yt_video_seg",
        "method": "GET",
        "uri": "https://rr3---sn-ogul7n7z.googlevideo.com/videoplayback?id=seg001",
        "shared": 1,
        "req_time": T0 + 2,
        "resp_time": T0 + 2,
        "lookup_time": T0 + 200,
        "status": 200,
        "req_h": [("origin", "https://www.youtube.com")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("age", "40"),
            ("cache-control", "public, s-maxage=3600, max-age=600"),
            ("etag", '"seg-001"'),
            ("content-type", "video/mp4"),
        ],
        "lookup_req_h": [("origin", "https://www.youtube.com")],
        "reval_304_h": [],
    },
    # 4. Twitter/X HomeTimeline GraphQL API (no-store -> not storable)
    {
        "id": "x_timeline_api",
        "method": "GET",
        "uri": "https://x.com/i/api/graphql/HomeTimeline",
        "shared": 0,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 5,
        "status": 200,
        "req_h": [("authorization", "Bearer AAAA"), ("accept", "application/json")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "no-cache, no-store, max-age=0"),
            ("content-type", "application/json"),
        ],
        "lookup_req_h": [("authorization", "Bearer AAAA"), ("accept", "application/json")],
        "reval_304_h": [],
    },
    # 5. Twitter/X twimg CDN media (public, max-age=604800, Vary mismatch test)
    {
        "id": "x_twimg_vary_miss",
        "method": "GET",
        "uri": "https://pbs.twimg.com/media/F9abc123.jpg?format=webp",
        "shared": 1,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 300,
        "status": 200,
        "req_h": [("accept", "image/webp")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "public, max-age=604800"),
            ("vary", "Accept"),
            ("etag", '"img-webp-1"'),
        ],
        "lookup_req_h": [("accept", "image/avif")],
        "reval_304_h": [],
    },
    # 6. Cloudflare CDN CSS bundle (stale -> conditional revalidation + 304 refresh)
    {
        "id": "cf_cdn_css_304",
        "method": "GET",
        "uri": "https://cdn.example.com/assets/app.8f91a.css",
        "shared": 1,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 400,
        "status": 200,
        "req_h": [("accept-encoding", "br")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "public, max-age=300"),
            ("vary", "Accept-Encoding"),
            ("etag", '"css-v10"'),
            ("last-modified", "Tue, 14 Nov 2023 20:00:00 GMT"),
        ],
        "lookup_req_h": [("accept-encoding", "br")],
        "reval_304_h": [
            ("date", "Tue, 14 Nov 2023 22:20:00 GMT"),
            ("cache-control", "public, max-age=900"),
            ("etag", '"css-v10"'),
        ],
    },
    # 7. GitHub REST API (ETag + max-age=60, stale at +90, 304 refresh)
    {
        "id": "github_repo_api",
        "method": "GET",
        "uri": "https://api.github.com/repos/AFK-surf/pion-packages",
        "shared": 0,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 90,
        "status": 200,
        "req_h": [("accept", "application/vnd.github+json"), ("accept-encoding", "gzip")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "private, max-age=60, s-maxage=60"),
            ("vary", "Accept, Accept-Encoding"),
            ("etag", 'W/"gh-abc-123"'),
            ("last-modified", "Tue, 14 Nov 2023 22:00:00 GMT"),
        ],
        "lookup_req_h": [("accept", "application/vnd.github+json"), ("accept-encoding", "gzip")],
        "reval_304_h": [
            ("date", "Tue, 14 Nov 2023 22:14:50 GMT"),
            ("cache-control", "private, max-age=60"),
            ("etag", 'W/"gh-abc-123"'),
        ],
    },
    # 8. Private response on shared cache -> not storable
    {
        "id": "shared_private_reject",
        "method": "GET",
        "uri": "https://api.example.com/v1/account",
        "shared": 1,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 10,
        "status": 200,
        "req_h": [("accept", "application/json")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "private, max-age=300"),
        ],
        "lookup_req_h": [("accept", "application/json")],
        "reval_304_h": [],
    },
    # 9. Shared cache with Authorization + no public/s-maxage/must-revalidate -> not storable
    {
        "id": "shared_auth_reject",
        "method": "GET",
        "uri": "https://api.example.com/v1/profile",
        "shared": 1,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 10,
        "status": 200,
        "req_h": [("authorization", "Bearer secret")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "max-age=300"),
        ],
        "lookup_req_h": [("authorization", "Bearer secret")],
        "reval_304_h": [],
    },
    # 10. Expires-based freshness (no Cache-Control)
    {
        "id": "legacy_expires_fresh",
        "method": "GET",
        "uri": "https://static.example.org/fonts/inter.woff2",
        "shared": 1,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 1000,
        "status": 200,
        "req_h": [],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("expires", "Tue, 14 Nov 2023 23:13:20 GMT"),
            ("etag", '"font-v1"'),
        ],
        "lookup_req_h": [],
        "reval_304_h": [],
    },
    # 11. Heuristic freshness from Last-Modified (10% of 10000s = 1000s)
    {
        "id": "heuristic_last_modified",
        "method": "GET",
        "uri": "https://docs.example.org/guide.html",
        "shared": 0,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 500,
        "status": 200,
        "req_h": [],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("last-modified", "Tue, 14 Nov 2023 19:26:40 GMT"),
        ],
        "lookup_req_h": [],
        "reval_304_h": [],
    },
    # 12. Request no-store -> not storable even if response has public, max-age
    {
        "id": "req_no_store_reject",
        "method": "GET",
        "uri": "https://ads.example.com/bid",
        "shared": 1,
        "req_time": T0,
        "resp_time": T0,
        "lookup_time": T0 + 1,
        "status": 200,
        "req_h": [("cache-control", "no-store")],
        "resp_h": [
            ("date", "Tue, 14 Nov 2023 22:13:20 GMT"),
            ("cache-control", "public, max-age=60"),
        ],
        "lookup_req_h": [],
        "reval_304_h": [],
    },
]


def main() -> None:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-http-cache-bench"
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "corpus.txt")
    lines = []
    for c in CASES:
        lines.append(
            f"CASE\t{c['id']}\t{c['method']}\t{c['uri']}\t{c['shared']}\t"
            f"{c['req_time']}\t{c['resp_time']}\t{c['lookup_time']}\t{c['status']}"
        )
        for k, v in c["req_h"]:
            lines.append(f"RQ\t{k}\t{v}")
        for k, v in c["resp_h"]:
            lines.append(f"RS\t{k}\t{v}")
        for k, v in c["lookup_req_h"]:
            lines.append(f"LQ\t{k}\t{v}")
        for k, v in c["reval_304_h"]:
            lines.append(f"R3\t{k}\t{v}")
        lines.append("END")
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Wrote {len(CASES)} cases -> {out_path} ({os.path.getsize(out_path)} bytes)")


if __name__ == "__main__":
    main()
