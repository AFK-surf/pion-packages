/* Real macOS OpenGL 4.1 Core Profile shader compiler verification harness.
 * Compile: clang -O2 -Wall -Wno-deprecated-declarations verify_gl41.c -framework OpenGL -o verify_gl41
 * Usage:   verify_gl41 <vert|frag>:<path> [<vert|frag>:<path> ...]
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_entire_file(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
  long sz = ftell(f);
  if (sz < 0) { fclose(f); return NULL; }
  rewind(f);
  char *buf = (char *)malloc((size_t)sz + 1);
  if (!buf) { fclose(f); return NULL; }
  size_t rd = fread(buf, 1, (size_t)sz, f);
  buf[rd] = '\0';
  fclose(f);
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <vert|frag>:<path> [...]\n", argv[0]);
    return 1;
  }

  CGLPixelFormatAttribute attrs[] = {
    kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
    kCGLPFAAccelerated,
    (CGLPixelFormatAttribute)0
  };
  CGLPixelFormatObj pix = NULL;
  GLint npix = 0;
  CGLError err = CGLChoosePixelFormat(attrs, &pix, &npix);
  if (err != kCGLNoError || !pix) {
    /* Fallback without kCGLPFAAccelerated for headless software renderer */
    CGLPixelFormatAttribute sw_attrs[] = {
      kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
      (CGLPixelFormatAttribute)0
    };
    err = CGLChoosePixelFormat(sw_attrs, &pix, &npix);
    if (err != kCGLNoError || !pix) {
      fprintf(stderr, "CGLChoosePixelFormat failed: %d\n", (int)err);
      return 2;
    }
  }

  CGLContextObj ctx = NULL;
  err = CGLCreateContext(pix, NULL, &ctx);
  CGLDestroyPixelFormat(pix);
  if (err != kCGLNoError || !ctx) {
    fprintf(stderr, "CGLCreateContext failed: %d\n", (int)err);
    return 3;
  }
  CGLSetCurrentContext(ctx);

  const char *gl_ver = (const char *)glGetString(GL_VERSION);
  const char *glsl_ver = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
  printf("macOS OpenGL Core: %s | GLSL: %s\n",
         gl_ver ? gl_ver : "unknown",
         glsl_ver ? glsl_ver : "unknown");

  int failed = 0;
  for (int i = 1; i < argc; i++) {
    const char *arg = argv[i];
    const char *colon = strchr(arg, ':');
    if (!colon) {
      fprintf(stderr, "invalid arg (expected vert:path or frag:path): %s\n", arg);
      failed = 1;
      continue;
    }
    GLenum stype = 0;
    if (strncmp(arg, "vert:", 5) == 0) {
      stype = GL_VERTEX_SHADER;
    } else if (strncmp(arg, "frag:", 5) == 0) {
      stype = GL_FRAGMENT_SHADER;
    } else {
      fprintf(stderr, "unknown stage in arg: %s\n", arg);
      failed = 1;
      continue;
    }
    const char *path = colon + 1;
    char *src = read_entire_file(path);
    if (!src) {
      fprintf(stderr, "failed to read: %s\n", path);
      failed = 1;
      continue;
    }

    GLuint sh = glCreateShader(stype);
    const char *srcs[1] = { src };
    glShaderSource(sh, 1, srcs, NULL);
    glCompileShader(sh);

    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (ok == GL_TRUE) {
      printf("  [PASS] glCompileShader(%s)\n", arg);
    } else {
      GLint log_len = 0;
      glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &log_len);
      char *log = (char *)calloc((size_t)(log_len > 0 ? log_len + 1 : 256), 1);
      glGetShaderInfoLog(sh, log_len, NULL, log);
      fprintf(stderr, "  [FAIL] glCompileShader(%s):\n%s\n", arg, log);
      free(log);
      failed = 1;
    }
    glDeleteShader(sh);
    free(src);
  }

  CGLSetCurrentContext(NULL);
  CGLDestroyContext(ctx);
  return failed ? 4 : 0;
}
