/* Ground-truth judge: macOS OpenGL.framework (CGL, 4.1 Core profile) glCompileShader + glLinkProgram.
 * Build: clang -O2 -Wno-deprecated-declarations gl41_oracle.c -framework OpenGL -o gl41_oracle
 * Usage: gl41_oracle <manifest>
 *   manifest lines: <case-name>\t<vertex.glsl|->\t<fragment.glsl|->
 *   "-" substitutes a minimal pass-through shader of that stage.
 * Output, one line per case:
 *   <case> VS=ok|FAIL FS=ok|FAIL LINK=ok|FAIL|skip fragcolor_loc=<n> | <first error line of the failing step>
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *DEF_VS = "#version 410 core\nvoid main(){gl_Position=vec4(0.0);}\n";
static const char *DEF_FS = "#version 410 core\nout vec4 o;\nvoid main(){o=vec4(1.0);}\n";

static char *slurp(const char *p) {
  FILE *f = fopen(p, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  rewind(f);
  char *b = malloc((size_t)n + 1);
  size_t r = fread(b, 1, (size_t)n, f);
  b[r] = 0;
  fclose(f);
  return b;
}

static void first_line(char *dst, size_t cap, const char *log) {
  size_t i = 0;
  while (log[i] && log[i] != '\n' && i + 1 < cap) { dst[i] = log[i]; i++; }
  dst[i] = 0;
}

static GLuint compile(GLenum t, const char *src, int *ok, char *msg, size_t cap) {
  GLuint s = glCreateShader(t);
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  GLint st = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &st);
  *ok = st == GL_TRUE;
  if (!*ok) {
    char log[4096] = {0};
    glGetShaderInfoLog(s, sizeof log, NULL, log);
    first_line(msg, cap, log);
  }
  return s;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <manifest>\n", argv[0]); return 2; }
  CGLPixelFormatAttribute a[] = {kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, 0};
  CGLPixelFormatObj pf; GLint np;
  if (CGLChoosePixelFormat(a, &pf, &np) != kCGLNoError || !pf) { fprintf(stderr, "no pixel format\n"); return 3; }
  CGLContextObj ctx;
  if (CGLCreateContext(pf, NULL, &ctx) != kCGLNoError) { fprintf(stderr, "no context\n"); return 3; }
  CGLSetCurrentContext(ctx);
  GLint mdb = 0; glGetIntegerv(GL_MAX_DRAW_BUFFERS, &mdb);
  fprintf(stderr, "# %s | GLSL %s | renderer %s | MAX_DRAW_BUFFERS %d\n", glGetString(GL_VERSION),
          glGetString(GL_SHADING_LANGUAGE_VERSION), glGetString(GL_RENDERER), mdb);
  FILE *m = fopen(argv[1], "r");
  if (!m) return 2;
  char line[8192];
  while (fgets(line, sizeof line, m)) {
    line[strcspn(line, "\r\n")] = 0;
    char *name = strtok(line, "\t"), *vp = strtok(NULL, "\t"), *fp = strtok(NULL, "\t");
    if (!name || !vp || !fp) continue;
    char *vs = strcmp(vp, "-") ? slurp(vp) : strdup(DEF_VS);
    char *fs = strcmp(fp, "-") ? slurp(fp) : strdup(DEF_FS);
    char vmsg[512] = "", fmsg[512] = "", lmsg[512] = "";
    if (!vs || !fs) { printf("%s IOERR\n", name); continue; }
    int vok, fok, lok = 0;
    GLuint v = compile(GL_VERTEX_SHADER, vs, &vok, vmsg, sizeof vmsg);
    GLuint f = compile(GL_FRAGMENT_SHADER, fs, &fok, fmsg, sizeof fmsg);
    GLint loc = -2;
    if (vok && fok) {
      GLuint p = glCreateProgram();
      glAttachShader(p, v); glAttachShader(p, f);
      glLinkProgram(p);
      GLint st = 0; glGetProgramiv(p, GL_LINK_STATUS, &st);
      lok = st == GL_TRUE;
      if (!lok) { char log[4096] = {0}; glGetProgramInfoLog(p, sizeof log, NULL, log); first_line(lmsg, sizeof lmsg, log); }
      else loc = glGetFragDataLocation(p, "_fv_gl_FragColor");
      glDeleteProgram(p);
    }
    glDeleteShader(v); glDeleteShader(f);
    printf("%s VS=%s FS=%s LINK=%s fragcolor_loc=%d |%s%s%s\n", name, vok ? "ok" : "FAIL", fok ? "ok" : "FAIL",
           (vok && fok) ? (lok ? "ok" : "FAIL") : "skip", loc, vmsg, fmsg, lmsg);
    free(vs); free(fs);
  }
  return 0;
}
