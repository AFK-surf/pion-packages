#include <brotli/decode.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t fnv1a_64_update(uint64_t h, const uint8_t *data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    h = (h ^ (uint64_t)data[i]) * 1099511628211ULL;
  }
  return h;
}

static uint32_t read_u32_le(const uint8_t *b, size_t off) {
  return (uint32_t)b[off] | ((uint32_t)b[off + 1] << 8) |
         ((uint32_t)b[off + 2] << 16) | ((uint32_t)b[off + 3] << 24);
}

static uint8_t *read_file(const char *path, size_t *out_len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz < 0) {
    fclose(f);
    return NULL;
  }
  uint8_t *buf = (uint8_t *)malloc((size_t)sz);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
    free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  *out_len = (size_t)sz;
  return buf;
}

static uint8_t *decompress_one(const uint8_t *in, size_t in_len, size_t *out_len) {
  size_t cap = in_len * 4 + 256;
  uint8_t *out = (uint8_t *)malloc(cap);
  if (!out) return NULL;

  BrotliDecoderState *st = BrotliDecoderCreateInstance(NULL, NULL, NULL);
  if (!st) {
    free(out);
    return NULL;
  }

  size_t avail_in = in_len;
  const uint8_t *next_in = in;
  size_t total_out = 0;

  for (;;) {
    size_t avail_out = cap - total_out;
    if (avail_out == 0) {
      cap *= 2;
      uint8_t *nb = (uint8_t *)realloc(out, cap);
      if (!nb) {
        free(out);
        BrotliDecoderDestroyInstance(st);
        return NULL;
      }
      out = nb;
      avail_out = cap - total_out;
    }
    uint8_t *next_out = out + total_out;
    BrotliDecoderResult res = BrotliDecoderDecompressStream(
        st, &avail_in, &next_in, &avail_out, &next_out, &total_out);
    if (res == BROTLI_DECODER_RESULT_SUCCESS) {
      BrotliDecoderDestroyInstance(st);
      *out_len = total_out;
      return out;
    }
    if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
      continue;
    }
    free(out);
    BrotliDecoderDestroyInstance(st);
    return NULL;
  }
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: brotli_bench <decode|batch> <file> <iters> [dump_path]\n");
    return 1;
  }
  const char *mode = argv[1];
  const char *path = argv[2];
  int iters = atoi(argv[3]);

  size_t data_len = 0;
  uint8_t *data = read_file(path, &data_len);
  if (!data) {
    fprintf(stderr, "failed to read %s\n", path);
    return 1;
  }

  if (strcmp(mode, "decode") == 0) {
    uint8_t *last_out = NULL;
    size_t last_len = 0;
    uint64_t total_bytes = 0;
    for (int i = 0; i < iters; i++) {
      size_t out_len = 0;
      uint8_t *out = decompress_one(data, data_len, &out_len);
      if (!out) {
        fprintf(stderr, "brotli decompress failed\n");
        free(last_out);
        free(data);
        return 1;
      }
      total_bytes += (uint64_t)out_len;
      free(last_out);
      last_out = out;
      last_len = out_len;
    }
    if (argc >= 5 && last_out) {
      FILE *df = fopen(argv[4], "wb");
      if (df) {
        fwrite(last_out, 1, last_len, df);
        fclose(df);
      }
    }
    uint64_t h = fnv1a_64_update(14695981039346656037ULL, last_out, last_len);
    printf("mode=decode iters=%d total_bytes=%llu last_len=%zu fnv64=%016llx\n",
           iters, (unsigned long long)total_bytes, last_len, (unsigned long long)h);
    free(last_out);
    free(data);
    return 0;
  }

  if (strcmp(mode, "batch") == 0) {
    uint32_t count = read_u32_le(data, 0);
    const uint8_t **ptrs = (const uint8_t **)malloc(count * sizeof(uint8_t *));
    size_t *lens = (size_t *)malloc(count * sizeof(size_t));
    size_t off = 4;
    for (uint32_t i = 0; i < count; i++) {
      uint32_t plen = read_u32_le(data, off);
      off += 4;
      ptrs[i] = data + off;
      lens[i] = (size_t)plen;
      off += plen;
    }
    uint64_t total_bytes = 0;
    uint64_t total_packets = 0;
    uint64_t last_hash = 14695981039346656037ULL;
    for (int r = 0; r < iters; r++) {
      uint64_t h = 14695981039346656037ULL;
      for (uint32_t i = 0; i < count; i++) {
        size_t out_len = 0;
        uint8_t *out = decompress_one(ptrs[i], lens[i], &out_len);
        if (!out) {
          fprintf(stderr, "batch decompress failed at %u\n", i);
          free(ptrs);
          free(lens);
          free(data);
          return 1;
        }
        total_bytes += (uint64_t)out_len;
        total_packets += 1;
        if (r == iters - 1) {
          h = fnv1a_64_update(h, out, out_len);
        }
        free(out);
      }
      if (r == iters - 1) {
        last_hash = h;
      }
    }
    printf("mode=batch iters=%d packets=%llu total_bytes=%llu fnv64=%016llx\n",
           iters, (unsigned long long)total_packets,
           (unsigned long long)total_bytes, (unsigned long long)last_hash);
    free(ptrs);
    free(lens);
    free(data);
    return 0;
  }

  fprintf(stderr, "unknown mode: %s\n", mode);
  free(data);
  return 1;
}
