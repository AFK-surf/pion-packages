/* In-process libwebp lossless encode benchmark harness for packages/webp.
 * Usage: libwebp_encode_bench <rgba_file> <w> <h> <z_level> <iters> [exact] [out_webp]
 * Reads <rgba_file> once into RAM, encodes <iters> times in-process via WebPEncode
 * with WebPConfigLosslessPreset(&config, z_level), optionally writes the final encoded
 * WebP to out_webp, decodes the final WebP back to RGBA8888 via WebPDecodeRGBA,
 * and writes the decoded RGBA8888 bytes to stdout for SHA-256 verification.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <webp/decode.h>
#include <webp/encode.h>

int main(int argc, char **argv) {
  if (argc < 6) {
    fprintf(stderr, "usage: %s <rgba_file> <w> <h> <z_level> <iters> [exact] [out_webp]\n", argv[0]);
    return 1;
  }
  const char *rgba_path = argv[1];
  int w = atoi(argv[2]);
  int h = atoi(argv[3]);
  int z_level = atoi(argv[4]);
  int iters = atoi(argv[5]);
  int use_exact = (argc >= 7 && strcmp(argv[6], "exact") == 0) ? 1 : 0;
  const char *out_webp_path = (argc >= 8) ? argv[7] : NULL;

  if (w <= 0 || h <= 0 || iters <= 0) {
    fprintf(stderr, "invalid arguments: w=%d h=%d iters=%d\n", w, h, iters);
    return 1;
  }

  size_t expected = (size_t)w * (size_t)h * 4;
  uint8_t *rgba = (uint8_t *)malloc(expected);
  if (!rgba) {
    fprintf(stderr, "malloc failed\n");
    return 1;
  }
  FILE *f = fopen(rgba_path, "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", rgba_path);
    free(rgba);
    return 1;
  }
  if (fread(rgba, 1, expected, f) != expected) {
    fprintf(stderr, "short read on %s\n", rgba_path);
    fclose(f);
    free(rgba);
    return 1;
  }
  fclose(f);

  WebPConfig config;
  if (!WebPConfigInit(&config) || !WebPConfigLosslessPreset(&config, z_level)) {
    fprintf(stderr, "WebPConfigLosslessPreset failed\n");
    free(rgba);
    return 1;
  }
  config.exact = use_exact;
  if (!WebPValidateConfig(&config)) {
    fprintf(stderr, "invalid WebPConfig\n");
    free(rgba);
    return 1;
  }

  WebPPicture pic;
  if (!WebPPictureInit(&pic)) {
    fprintf(stderr, "WebPPictureInit failed\n");
    free(rgba);
    return 1;
  }
  pic.width = w;
  pic.height = h;
  pic.use_argb = 1;
  if (!WebPPictureImportRGBA(&pic, rgba, w * 4)) {
    fprintf(stderr, "WebPPictureImportRGBA failed\n");
    free(rgba);
    return 1;
  }

  uint8_t *last_buf = NULL;
  size_t last_size = 0;
  for (int i = 0; i < iters; i++) {
    WebPMemoryWriter wrt;
    WebPMemoryWriterInit(&wrt);
    pic.writer = WebPMemoryWrite;
    pic.custom_ptr = &wrt;
    if (!WebPEncode(&config, &pic)) {
      fprintf(stderr, "WebPEncode failed (error=%d)\n", pic.error_code);
      WebPMemoryWriterClear(&wrt);
      WebPPictureFree(&pic);
      free(last_buf);
      free(rgba);
      return 1;
    }
    if (i == iters - 1) {
      last_buf = wrt.mem;
      last_size = wrt.size;
    } else {
      WebPMemoryWriterClear(&wrt);
    }
  }
  WebPPictureFree(&pic);
  free(rgba);

  if (out_webp_path && last_buf) {
    FILE *of = fopen(out_webp_path, "wb");
    if (!of) {
      fprintf(stderr, "failed to open %s\n", out_webp_path);
      WebPFree(last_buf);
      return 1;
    }
    int write_ok = fwrite(last_buf, 1, last_size, of) == last_size;
    int close_ok = fclose(of) == 0;
    if (!write_ok || !close_ok) {
      fprintf(stderr, "failed to write %s\n", out_webp_path);
      WebPFree(last_buf);
      return 1;
    }
  }

  int dw = 0, dh = 0;
  uint8_t *decoded = WebPDecodeRGBA(last_buf, last_size, &dw, &dh);
  WebPFree(last_buf);
  if (!decoded || dw != w || dh != h) {
    fprintf(stderr, "WebPDecodeRGBA failed\n");
    if (decoded) WebPFree(decoded);
    return 1;
  }
  if (fwrite(decoded, 1, expected, stdout) != expected || fflush(stdout) != 0) {
    fprintf(stderr, "stdout write failed\n");
    WebPFree(decoded);
    return 1;
  }
  WebPFree(decoded);
  return 0;
}
