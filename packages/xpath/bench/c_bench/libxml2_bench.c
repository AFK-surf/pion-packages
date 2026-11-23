/* C libxml2 (-O2) head-to-head benchmark binary for packages/xpath (W1..W5). */
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void quiet_generic(void *ctx, const char *msg, ...) {
  (void)ctx;
  (void)msg;
}
static void quiet_struct(void *ctx, xmlErrorPtr err) {
  (void)ctx;
  (void)err;
}

static int64_t eval_compiled_int(xmlXPathCompExprPtr comp, xmlXPathContextPtr ctx, xmlDocPtr doc) {
  ctx->node = (xmlNodePtr)doc;
  xmlXPathObjectPtr obj = xmlXPathCompiledEval(comp, ctx);
  if (!obj) return -1;
  double num = xmlXPathCastToNumber(obj);
  xmlXPathFreeObject(obj);
  return (int64_t)num;
}

static int64_t eval_str_int(const char *q, xmlXPathContextPtr ctx, xmlDocPtr doc) {
  ctx->node = (xmlNodePtr)doc;
  xmlXPathObjectPtr obj = xmlXPathEvalExpression((const xmlChar *)q, ctx);
  if (!obj) return -1;
  double num = xmlXPathCastToNumber(obj);
  xmlXPathFreeObject(obj);
  return (int64_t)num;
}

static void run_precompiled(const char *tag, const char **queries, int nq, xmlDocPtr doc, int rounds) {
  xmlXPathContextPtr ctx = xmlXPathNewContext(doc);
  xmlXPathCompExprPtr *compiled = malloc((size_t)nq * sizeof(xmlXPathCompExprPtr));
  for (int i = 0; i < nq; i++) {
    compiled[i] = xmlXPathCompile((const xmlChar *)queries[i]);
    if (!compiled[i]) {
      fprintf(stderr, "compile failed: %s\n", queries[i]);
      exit(1);
    }
  }
  int64_t acc = 0;
  int64_t first[16];
  for (int r = 0; r < rounds; r++) {
    for (int q = 0; q < nq; q++) {
      acc += eval_compiled_int(compiled[q], ctx, doc);
    }
    if (r == 0) {
      for (int q = 0; q < nq; q++) {
        first[q] = eval_compiled_int(compiled[q], ctx, doc);
      }
    }
  }
  printf("%s rounds=%d sum=%lld vec=", tag, rounds, (long long)acc);
  for (int q = 0; q < nq && rounds > 0; q++) {
    if (q > 0) putchar(',');
    printf("%lld", (long long)first[q]);
  }
  putchar('\n');
  for (int i = 0; i < nq; i++) xmlXPathFreeCompExpr(compiled[i]);
  free(compiled);
  xmlXPathFreeContext(ctx);
}

static void run_w2(xmlDocPtr doc, int iters) {
  const char *queries[] = {
      "count(/store/item[@lang='en'])",
      "sum(/store/item[@stock > 0]/cost)",
      "string-length(string(/store/item[@id='i10']/name))",
      "count(/store/item/meta[tier = 2])",
      "number(/store/item[5]/cost) * 2",
      "count(/store/item[starts-with(meta/sku, 'SKU-002')])",
      "count(/store/item[@lang='fr' or @lang='de'])",
      "string-length(concat(/store/item[1]/name, '-', /store/item[2]/name))",
      "count(/store/item[cost >= 30 and cost <= 50])",
      "count(/store/item[last()]/preceding-sibling::item[@lang='ja'])",
  };
  int nq = (int)(sizeof(queries) / sizeof(queries[0]));
  xmlXPathContextPtr ctx = xmlXPathNewContext(doc);
  int64_t acc = 0;
  for (int i = 0; i < iters; i++) {
    acc += eval_str_int(queries[i % nq], ctx, doc);
  }
  printf("w2 iters=%d sum=%lld\n", iters, (long long)acc);
  xmlXPathFreeContext(ctx);
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: c_xpath <w1|w2|w3|w4|w5> <xml_path> <iters>\n");
    return 1;
  }
  const char *mode = argv[1];
  const char *path = argv[2];
  int iters = atoi(argv[3]);

  FILE *f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", path);
    return 1;
  }
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc((size_t)sz + 1);
  if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
    fclose(f);
    free(buf);
    return 1;
  }
  buf[sz] = 0;
  fclose(f);

  xmlSetGenericErrorFunc(NULL, quiet_generic);
  xmlSetStructuredErrorFunc(NULL, quiet_struct);
  xmlDocPtr doc = xmlReadMemory(buf, (int)sz, "bench.xml", "UTF-8", XML_PARSE_NOCDATA | XML_PARSE_NONET);
  free(buf);
  if (!doc) {
    fprintf(stderr, "xml parse failed\n");
    return 1;
  }

  if (!strcmp(mode, "w1")) {
    const char *q[] = {
        "count(/catalog/section/book[@available='true' and price >= 50])",
        "sum(/catalog/section[@name='systems']/book/price)",
        "count(//book[@lang='en' or @lang='ja'][year >= 2015])",
        "count(//book[tags/tag = 'wasm' and tags/tag = 'core'])",
        "string-length(normalize-space((//book[@id='b1500']/title)[1]))",
        "count(/catalog/section[1]/book[position() <= 20] | /catalog/section[last()]/book[position() > 280])",
        "sum(//section[@name='compilers']/book[@available='true']/price)",
        "count(//book[contains(summary, 'security') and price < 40])",
        "count(//book[starts-with(@id, 'b10')]/tags/tag)",
        "count(//section[@name='ml']/book[1]/following-sibling::book[@lang='en'])",
    };
    run_precompiled("w1", q, 10, doc, iters);
  } else if (!strcmp(mode, "w2")) {
    run_w2(doc, iters);
  } else if (!strcmp(mode, "w3")) {
    const char *q[] = {
        "count(descendant-or-self::*[ancestor::dept[@region='r0'] and @active='yes'])",
        "sum(descendant-or-self::project[ancestor::team[@tier='1']]/budget)",
        "count(//project[@active='yes']/following-sibling::project[@active='yes'])",
        "sum(//milestone[ancestor::dept[@region='r2']]/hours)",
        "count(//project[string-length(normalize-space(label)) >= 8])",
    };
    run_precompiled("w3", q, 5, doc, iters);
  } else if (!strcmp(mode, "w4")) {
    const char *q[] = {
        "number(//a = //b)",
        "number(//a != //b)",
        "number(//a < //b)",
        "number(//a > //b)",
    };
    run_precompiled("w4", q, 4, doc, iters);
  } else {
    const char *q[] = {
        "count(/r/e)",
        "count(//@k)",
        "count(//e[@k >= 25000])",
        "sum(//e[@k < 1000]/@k)",
    };
    run_precompiled("w5", q, 4, doc, iters);
  }

  xmlFreeDoc(doc);
  return 0;
}
