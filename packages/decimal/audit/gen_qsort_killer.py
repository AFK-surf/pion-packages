#!/usr/bin/env python3
"""McIlroy "antiqsort" adversary against `Decimal::sort` (packages/decimal/src/cmp.pion @ 9128ea9).

usage: gen_qsort_killer.py <n> <out.txt>   -> n decimal strings (one per line)

The Pion sort is a deterministic median-of-three quicksort (pivot = median of lo/mid/hi, Hoare
partition, insertion sort below 17 elements, no introsort fallback). Following M. D. McIlroy,
"A Killer Adversary for Quicksort" (1999), we run an exact Python port of that algorithm with a
comparator that decides values lazily ("gas" -> "solid"), so every partition is as lopsided as the
algorithm permits. Because the real sort is deterministic, replaying the resulting permutation
forces exactly the same comparison sequence: Theta(n^2) comparisons. The values are emitted as
2-decimal currency amounts so the input looks like any ledger column.
"""
import sys

sys.setrecursionlimit(100000)


def killer(n):
    gas = n
    val = [gas] * n
    state = {"solid": 0, "cand": 0, "ncmp": 0}

    def freeze(x):
        val[x] = state["solid"]
        state["solid"] += 1

    def cmp(x, y):  # returns <0, 0, >0 like Decimal::compare(arr[x], arr[y])
        state["ncmp"] += 1
        if val[x] == gas and val[y] == gas:
            if x == state["cand"]:
                freeze(x)
            else:
                freeze(y)
        if val[x] == gas:
            state["cand"] = x
        elif val[y] == gas:
            state["cand"] = y
        return val[x] - val[y]

    arr = list(range(n))

    def insertion(lo, hi):
        i = lo + 1
        while i <= hi:
            key = arr[i]
            j = i - 1
            while j >= lo and cmp(arr[j], key) > 0:
                arr[j + 1] = arr[j]
                j -= 1
            arr[j + 1] = key
            i += 1

    def qs(lo, hi):
        while hi - lo > 16:
            mid = lo + ((hi - lo) >> 1)
            if cmp(arr[mid], arr[lo]) < 0:
                arr[lo], arr[mid] = arr[mid], arr[lo]
            if cmp(arr[hi], arr[lo]) < 0:
                arr[lo], arr[hi] = arr[hi], arr[lo]
            if cmp(arr[mid], arr[hi]) < 0:
                arr[mid], arr[hi] = arr[hi], arr[mid]
            pivot = arr[hi]
            i, j = lo - 1, hi
            while True:
                i += 1
                while cmp(arr[i], pivot) < 0:
                    i += 1
                j -= 1
                while j > lo and cmp(arr[j], pivot) > 0:
                    j -= 1
                if i >= j:
                    break
                arr[i], arr[j] = arr[j], arr[i]
            arr[i], arr[hi] = arr[hi], arr[i]
            if i - lo < hi - i:
                if i - 1 > lo:
                    qs(lo, i - 1)
                lo = i + 1
            else:
                if i + 1 < hi:
                    qs(i + 1, hi)
                hi = i - 1
        if hi > lo:
            insertion(lo, hi)

    qs(0, n - 1)
    # Remaining gas items were never distinguished: give them the largest values in index order.
    for x in range(n):
        if val[x] == gas:
            freeze(x)
    return val, state["ncmp"]


def main():
    n = int(sys.argv[1])
    vals, ncmp = killer(n)
    with open(sys.argv[2], "w") as f:
        for v in vals:
            f.write(f"{1000 + v}.{v % 100:02d}\n")
    print(f"qsort killer n={n}: {ncmp} comparisons in the simulated sort (n log2 n ~ {int(n * n.bit_length())})")


if __name__ == "__main__":
    main()
