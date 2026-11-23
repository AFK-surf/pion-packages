/* Red-team reference harness for packages/brotli: Google libbrotlidec / libbrotlienc (C).
 * Record format: repeated [u32 LE length][payload].
 *   batch <cases.bin> <limit>          -> per case: OK <len> <fnv64> | TRAIL <len> <fnv64> <nbytes> | ERR <code>
 *   enc <quality> <lgwin> <in.bin> <out.bin>  -> encode every record (same record format)
 *   dict <out>                         -> dump the RFC 7932 static dictionary (122,784 B)
 *   transforms <out>                   -> dump the 121 RFC 7932 transforms as [plen][prefix][type][slen][suffix]
 *   lut <out>                          -> dump the literal context lookup table (2,048 B)
 *   file <in> <limit>                  -> single-file decode (bombs / DoS probes)
 *   bench <in> <iters>                 -> one-shot BrotliDecoderDecompress loop (hot-path profile)
 */
#include <brotli/decode.h>
#include <brotli/encode.h>
/* common/dictionary.h is not installed; layout copied from brotli 1.x (exported by libbrotlicommon). */
typedef struct BrotliDictionary {
  uint8_t size_bits_by_length[32];
  uint32_t offsets_by_length[32];
  size_t data_size;
  const uint8_t *data;
} BrotliDictionary;
extern const BrotliDictionary *BrotliGetDictionary(void);
/* common/transform.h (layout copied from brotli 1.x). */
typedef struct BrotliTransforms {
  uint16_t prefix_suffix_size;
  const uint8_t *prefix_suffix;
  const uint16_t *prefix_suffix_map;
  uint32_t num_transforms;
  const uint8_t *transforms; /* (prefix_id, type, suffix_id) triplets */
  const uint8_t *params;
  int16_t cutOffTransforms[10];
} BrotliTransforms;
extern const BrotliTransforms *BrotliGetTransforms(void);
/* common/context.h: 4 modes x (256 p1 entries + 256 p2 entries). */
extern const uint8_t _kBrotliContextLookupTable[2048];
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t fnv(const uint8_t *d, size_t n) {
  uint64_t h = 14695981039346656037ULL;
  for (size_t i = 0; i < n; i++) h = (h ^ d[i]) * 1099511628211ULL;
  return h;
}

static uint8_t *slurp(const char *p, size_t *n) {
  FILE *f = fopen(p, "rb");
  if (!f) { perror(p); exit(3); }
  fseek(f, 0, SEEK_END); long s = ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t *b = malloc(s ? (size_t)s : 1);
  if (fread(b, 1, (size_t)s, f) != (size_t)s) exit(3);
  fclose(f); *n = (size_t)s; return b;
}

static uint32_t rd32(const uint8_t *b) { return b[0] | (b[1] << 8) | (b[2] << 16) | ((uint32_t)b[3] << 24); }

/* Streaming decode with a hard output cap (the decoder itself has no limit). */
static void decode_one(const uint8_t *in, size_t n, size_t limit, FILE *o) {
  BrotliDecoderState *s = BrotliDecoderCreateInstance(0, 0, 0);
  size_t cap = 1 << 16, len = 0;
  uint8_t *out = malloc(cap);
  const uint8_t *nx = in; size_t ai = n;
  BrotliDecoderResult r;
  for (;;) {
    if (cap - len < 65536 && cap < limit + 65536) { cap *= 2; out = realloc(out, cap); }
    size_t ao = cap - len; uint8_t *no = out + len;
    r = BrotliDecoderDecompressStream(s, &ai, &nx, &ao, &no, 0);
    len = (size_t)(no - out);
    if (len > limit) { fprintf(o, "ERR LIMIT\n"); goto done; }
    if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) continue;
    break;
  }
  if (r == BROTLI_DECODER_RESULT_SUCCESS) {
    if (ai) fprintf(o, "TRAIL %zu %llu %zu\n", len, (unsigned long long)fnv(out, len), ai);
    else fprintf(o, "OK %zu %llu\n", len, (unsigned long long)fnv(out, len));
  } else if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) {
    fprintf(o, "ERR EOF\n");
  } else {
    fprintf(o, "ERR %s\n", BrotliDecoderErrorString(BrotliDecoderGetErrorCode(s)));
  }
done:
  free(out);
  BrotliDecoderDestroyInstance(s);
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: c_audit batch|enc|dict|file ...\n"); return 2; }
  if (!strcmp(argv[1], "batch")) {
    size_t n; uint8_t *b = slurp(argv[2], &n);
    size_t limit = argc > 3 ? (size_t)strtoull(argv[3], 0, 10) : (16u << 20);
    for (size_t p = 0; p + 4 <= n;) { uint32_t l = rd32(b + p); p += 4; decode_one(b + p, l, limit, stdout); p += l; }
    return 0;
  }
  if (!strcmp(argv[1], "file")) {
    size_t n; uint8_t *b = slurp(argv[2], &n);
    size_t limit = argc > 3 ? (size_t)strtoull(argv[3], 0, 10) : (256u << 20);
    decode_one(b, n, limit, stdout);
    return 0;
  }
  if (!strcmp(argv[1], "enc") && argc >= 6) {
    int q = atoi(argv[2]), w = atoi(argv[3]);
    size_t n; uint8_t *b = slurp(argv[4], &n);
    FILE *o = fopen(argv[5], "wb");
    for (size_t p = 0; p + 4 <= n;) {
      uint32_t l = rd32(b + p); p += 4;
      size_t cap = BrotliEncoderMaxCompressedSize(l); if (!cap) cap = l + 1024;
      uint8_t *c = malloc(cap); size_t cl = cap;
      if (!BrotliEncoderCompress(q, w, BROTLI_MODE_GENERIC, l, b + p, &cl, c)) { fprintf(stderr, "enc fail\n"); return 1; }
      uint8_t h[4] = {cl & 255, (cl >> 8) & 255, (cl >> 16) & 255, (cl >> 24) & 255};
      fwrite(h, 1, 4, o); fwrite(c, 1, cl, o); free(c); p += l;
    }
    fclose(o);
    return 0;
  }
  if (!strcmp(argv[1], "bench") && argc >= 4) {
    size_t n; uint8_t *b = slurp(argv[2], &n);
    int it = atoi(argv[3]);
    size_t cap = 1u << 30, ol = 0;
    uint8_t *out = malloc(cap);
    for (int i = 0; i < it; i++) {
      ol = cap;
      if (BrotliDecoderDecompress(n, b, &ol, out) != BROTLI_DECODER_RESULT_SUCCESS) { puts("ERR"); return 1; }
    }
    printf("OK %zu %llu\n", ol, (unsigned long long)fnv(out, ol));
    return 0;
  }
  if (!strcmp(argv[1], "dict")) {
    const BrotliDictionary *d = BrotliGetDictionary();
    FILE *o = fopen(argv[2], "wb"); fwrite(d->data, 1, d->data_size, o); fclose(o);
    printf("%zu\n", (size_t)d->data_size);
    return 0;
  }
  if (!strcmp(argv[1], "transforms")) {
    const BrotliTransforms *t = BrotliGetTransforms();
    FILE *o = fopen(argv[2], "wb");
    for (uint32_t i = 0; i < t->num_transforms; i++) {
      const uint8_t *pre = &t->prefix_suffix[t->prefix_suffix_map[t->transforms[i * 3]]];
      const uint8_t *suf = &t->prefix_suffix[t->prefix_suffix_map[t->transforms[i * 3 + 2]]];
      fwrite(pre, 1, 1 + pre[0], o); fputc(t->transforms[i * 3 + 1], o); fwrite(suf, 1, 1 + suf[0], o);
    }
    fclose(o);
    printf("%u\n", t->num_transforms);
    return 0;
  }
  if (!strcmp(argv[1], "lut")) {
    FILE *o = fopen(argv[2], "wb"); fwrite(_kBrotliContextLookupTable, 1, 2048, o); fclose(o);
    return 0;
  }
  return 2;
}
