#!/usr/bin/env python3
"""Deterministic realistic SemVer 2.0.0 and Cargo VersionReq corpus generator."""

import sys


class XorShift64:
    def __init__(self, seed: int) -> None:
        self.s = seed & 0xFFFFFFFFFFFFFFFF

    def next(self) -> int:
        x = self.s
        x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF
        x ^= (x >> 7) & 0xFFFFFFFFFFFFFFFF
        x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF
        self.s = x
        return x

    def randrange(self, n: int) -> int:
        return self.next() % n


PRE_TAGS = ["alpha", "beta", "rc", "dev", "pre", "preview", "canary", "nightly"]
BUILD_HEX = [
    "a1b2c3d",
    "deadbeef",
    "5114f85",
    "c7fcc0e",
    "0851523",
    "20261122",
    "20261123.1",
    "linux.x86-64",
    "darwin.arm64",
    "zstd.1.5.0",
]


def gen_versions(path: str, count: int) -> None:
    rng = XorShift64(0x5E40E22026112301)
    lines = []
    for _ in range(count):
        r = rng.randrange(100)
        if r < 35:
            major = 0
            minor = rng.randrange(30)
            patch = rng.randrange(40)
        elif r < 85:
            major = 1 + rng.randrange(5)
            minor = rng.randrange(25)
            patch = rng.randrange(50)
        else:
            major = 6 + rng.randrange(40)
            minor = rng.randrange(100)
            patch = rng.randrange(200)

        s = f"{major}.{minor}.{patch}"
        kind = rng.randrange(100)
        if kind < 22:
            tag = PRE_TAGS[rng.randrange(len(PRE_TAGS))]
            sub = rng.randrange(4)
            if sub == 0:
                s += f"-{tag}.{rng.randrange(30)}"
            elif sub == 1:
                s += f"-{tag}.{rng.randrange(10)}.{rng.randrange(20)}"
            elif sub == 2:
                s += f"-{tag}{rng.randrange(15)}"
            else:
                s += f"-{tag}"
            if rng.randrange(5) == 0:
                s += f"+{BUILD_HEX[rng.randrange(len(BUILD_HEX))]}"
        elif kind < 30:
            s += f"+{BUILD_HEX[rng.randrange(len(BUILD_HEX))]}"
        lines.append(s)

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_reqs(path: str, count: int) -> None:
    rng = XorShift64(0x5E40E22026112302)
    lines = []
    for _ in range(count):
        major = rng.randrange(6)
        minor = rng.randrange(20)
        patch = rng.randrange(30)
        kind = rng.randrange(100)
        if kind < 30:
            s = f"^{major}.{minor}.{patch}"
        elif kind < 42:
            s = f"{major}.{minor}"
        elif kind < 52:
            s = f"~{major}.{minor}.{patch}"
        elif kind < 65:
            hi_maj = major + 1 + rng.randrange(2)
            s = f">={major}.{minor}.{patch}, <{hi_maj}.0.0"
        elif kind < 75:
            tag = PRE_TAGS[rng.randrange(4)]
            n = rng.randrange(10)
            s = f">={major}.{minor}.{patch}-{tag}.{n}, <{major + 1}.0.0"
        elif kind < 82:
            s = f"={major}.{minor}.{patch}"
        elif kind < 88:
            s = f">{major}.{minor}.0, <={major + 1}.{minor}.5"
        elif kind < 93:
            s = f"{major}.{minor}.*"
        elif kind < 97:
            s = f"{major}.*"
        else:
            s = "*"
        lines.append(s)

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_req32(path: str, count: int) -> None:
    rng = XorShift64(0x5E40E22026112303)
    lines = []
    for _ in range(count):
        parts = []
        for k in range(32):
            if k % 4 == 0:
                parts.append(f">={rng.randrange(2)}.{rng.randrange(5)}.{rng.randrange(5)}")
            elif k % 4 == 1:
                parts.append(f"<{2 + rng.randrange(3)}.{rng.randrange(5)}.0")
            elif k % 4 == 2:
                parts.append(f">={rng.randrange(2)}.{rng.randrange(5)}.{rng.randrange(5)}-alpha.{rng.randrange(5)}")
            else:
                parts.append(f"<= {2 + rng.randrange(2)}.{rng.randrange(6)}.{rng.randrange(10)}")
        lines.append(", ".join(parts))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def gen_dirty(path: str, count: int) -> None:
    rng = XorShift64(0x5E40E22026112304)
    samples = [
        "not-a-version",
        "01.2.3",
        "1.02.3",
        "1.2.3-",
        "1.2.3-01",
        "1.2.3+a..b",
        "18446744073709551616.0.0",
        "1.2.3 || 2.3.4",
        ">= >= 1.0.0",
        "1.2.3-alpha_1",
        "1.2.3.4",
        "v1.2.3",
        "*, 1.0.0",
        "1.*.2",
        "1.2.3-α",
        "   ",
    ]
    lines = [samples[rng.randrange(len(samples))] for _ in range(count)]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) < 5:
        print(
            "usage: gen_data.py <versions_out> <reqs_out> <num_versions> <num_reqs> [req32_out] [dirty_out]",
            file=sys.stderr,
        )
        return 1
    gen_versions(sys.argv[1], int(sys.argv[3]))
    gen_reqs(sys.argv[2], int(sys.argv[4]))
    if len(sys.argv) >= 6:
        gen_req32(sys.argv[5], 20000)
    if len(sys.argv) >= 7:
        gen_dirty(sys.argv[6], 100000)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
