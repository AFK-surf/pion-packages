/* libxml2 side of the RT-xpath differential harness: same PACK input / output format as
 * tools/pion_runner (see its header). Built against the system libxml2:
 *   cc -O2 -I$SDK/usr/include/libxml2 libxml2_oracle.c -lxml2
 * Documents are parsed with XML_PARSE_NOCDATA so CDATA sections become (merged) text nodes,
 * matching the XPath 1.0 data model; XML_PARSE_NONET keeps the oracle offline. */
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void esc(FILE *o, const char *s) {
  size_t n = s ? strlen(s) : 0, lim = n > 256 ? 256 : n;
  for (size_t i = 0; i < lim; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c == '\\') fputs("\\\\", o);
    else if (c == '\n') fputs("\\n", o);
    else if (c == '\r') fputs("\\r", o);
    else if (c == '\t') fputs("\\t", o);
    else if (c < 0x20 || c == 0x7f) fprintf(o, "\\x%02x", c);
    else fputc(c, o);
  }
  if (n > 256) fprintf(o, "...%zu", n);
}

static void emit_node(FILE *o, xmlNodePtr n) {
  const char *kind = "?";
  char name[1024] = "";
  if (n->type == XML_NAMESPACE_DECL) {
    xmlNsPtr ns = (xmlNsPtr)n;
    kind = "namespace";
    snprintf(name, sizeof name, "%s", ns->prefix ? (const char *)ns->prefix : "");
  } else {
    switch (n->type) {
    case XML_DOCUMENT_NODE: case XML_HTML_DOCUMENT_NODE: kind = "root"; break;
    case XML_ELEMENT_NODE: kind = "element"; break;
    case XML_ATTRIBUTE_NODE: kind = "attribute"; break;
    case XML_TEXT_NODE: case XML_CDATA_SECTION_NODE: kind = "text"; break;
    case XML_COMMENT_NODE: kind = "comment"; break;
    case XML_PI_NODE: kind = "pi"; break;
    default: kind = "other"; break;
    }
    if (n->type == XML_ELEMENT_NODE || n->type == XML_ATTRIBUTE_NODE) {
      if (n->ns && n->ns->prefix)
        snprintf(name, sizeof name, "%s:%s", n->ns->prefix, n->name);
      else
        snprintf(name, sizeof name, "%s", n->name);
    } else if (n->type == XML_PI_NODE) {
      snprintf(name, sizeof name, "%s", n->name);
    }
  }
  xmlChar *sv = xmlXPathCastNodeToString(n);
  fprintf(o, "  %s ", kind);
  esc(o, name);
  fputc(' ', o);
  esc(o, (const char *)sv);
  fputc('\n', o);
  xmlFree(sv);
}

static void emit(FILE *o, xmlXPathObjectPtr r) {
  switch (r->type) {
  case XPATH_NUMBER: {
    unsigned long long bits;
    memcpy(&bits, &r->floatval, 8);
    fprintf(o, "NUM %016llx\n", bits);
    break;
  }
  case XPATH_STRING: fputs("STR ", o); esc(o, (const char *)r->stringval); fputc('\n', o); break;
  case XPATH_BOOLEAN: fputs(r->boolval ? "BOOL true\n" : "BOOL false\n", o); break;
  case XPATH_NODESET: {
    int n = r->nodesetval ? r->nodesetval->nodeNr : 0;
    fprintf(o, "NODES %d\n", n);
    for (int i = 0; i < n; i++) emit_node(o, r->nodesetval->nodeTab[i]);
    break;
  }
  default: fputs("ERR\n", o);
  }
}

static void quiet(void *ctx, const char *msg, ...) { (void)ctx; (void)msg; }
static void squiet(void *ctx, xmlErrorPtr e) { (void)ctx; (void)e; }

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: libxml2_oracle PACK\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) return 2;
  fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
  char *buf = malloc(sz + 1); fread(buf, 1, sz, f); buf[sz] = 0; fclose(f);
  xmlSetGenericErrorFunc(NULL, quiet);
  xmlSetStructuredErrorFunc(NULL, squiet);
  FILE *o = stdout;
  xmlDocPtr doc = NULL; xmlXPathContextPtr ctx = NULL;
  long pos = 0; int qn = 0;
  while (pos < sz) {
    char *sp = strchr(buf + pos + 2, ' ');
    char *nl = strchr(sp, '\n');
    size_t tl = sp - (buf + pos + 2);
    char tag[8] = {0}; memcpy(tag, buf + pos + 2, tl < 7 ? tl : 7);
    long len = strtol(sp + 1, NULL, 10);
    char *body = malloc(len + 1); memcpy(body, nl + 1, len); body[len] = 0;
    pos = (nl + 1 - buf) + len + 1;
    if (!strcmp(tag, "DOC")) {
      if (ctx) xmlXPathFreeContext(ctx);
      if (doc) xmlFreeDoc(doc);
      ctx = NULL;
      doc = xmlReadMemory(body, (int)len, "pack.xml", "UTF-8", XML_PARSE_NOCDATA | XML_PARSE_NONET);
      if (!doc) fputs("=== DOCERR\n", o);
      else { ctx = xmlXPathNewContext(doc); }
    } else if (!strcmp(tag, "NS") || !strcmp(tag, "VARS") || !strcmp(tag, "VARN")) {
      char *s = strchr(body, ' ');
      if (ctx && s) {
        *s = 0;
        if (tag[0] == 'N') xmlXPathRegisterNs(ctx, (xmlChar *)body, (xmlChar *)(s + 1));
        else if (!strcmp(tag, "VARS")) xmlXPathRegisterVariable(ctx, (xmlChar *)body, xmlXPathNewCString(s + 1));
        else xmlXPathRegisterVariable(ctx, (xmlChar *)body, xmlXPathNewFloat(strtod(s + 1, NULL)));
      }
    } else if (!strcmp(tag, "Q")) {
      fprintf(o, "=== %d\n", qn++);
      if (!ctx) fputs("ERR\n", o);
      else {
        ctx->node = (xmlNodePtr)doc;
        xmlXPathObjectPtr r = xmlXPathEvalExpression((xmlChar *)body, ctx);
        if (!r) fputs("ERR\n", o); else { emit(o, r); xmlXPathFreeObject(r); }
      }
    }
    free(body);
  }
  return 0;
}
