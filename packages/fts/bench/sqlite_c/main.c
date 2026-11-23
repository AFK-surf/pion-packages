// Head-to-head SQLite FTS5 (C) baseline for packages/fts.
// Uses the exact same pre-tokenized `fts5_index_text` corpus and `fts5_match_expr` queries.

#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_all(const char *path, size_t *out_len) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    return NULL;
  }
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz < 0) {
    fclose(f);
    return NULL;
  }
  char *buf = (char *)malloc((size_t)sz + 1);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  size_t n = fread(buf, 1, (size_t)sz, f);
  buf[n] = '\0';
  fclose(f);
  *out_len = n;
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: sqlite_fts5_bench <fts5_tsv> <q_fts5> [reps]\n");
    return 2;
  }
  const char *corpus_path = argv[1];
  const char *q_path = argv[2];
  int reps = (argc >= 4) ? atoi(argv[3]) : 1;
  if (reps < 1) reps = 1;

  size_t corpus_len = 0, q_len = 0;
  char *corpus = read_all(corpus_path, &corpus_len);
  char *qbuf = read_all(q_path, &q_len);
  if (!corpus || !qbuf) return 1;

  sqlite3 *db = NULL;
  if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
    fprintf(stderr, "sqlite3_open failed\n");
    return 1;
  }
  char *errmsg = NULL;
  if (sqlite3_exec(
          db,
          "CREATE VIRTUAL TABLE docs USING fts5(body, tokenize=\"unicode61 tokenchars '_'\");",
          NULL, NULL, &errmsg) != SQLITE_OK) {
    fprintf(stderr, "create fts5 failed: %s\n", errmsg ? errmsg : "");
    return 1;
  }

  sqlite3_exec(db, "BEGIN;", NULL, NULL, NULL);
  sqlite3_stmt *ins = NULL;
  sqlite3_prepare_v2(db, "INSERT INTO docs(rowid, body) VALUES (?, ?);", -1, &ins, NULL);

  int doc_count = 0;
  char *p = corpus;
  char *end = corpus + corpus_len;
  while (p < end) {
    char *nl = (char *)memchr(p, '\n', (size_t)(end - p));
    char *line_end = nl ? nl : end;
    char *tab = (char *)memchr(p, '\t', (size_t)(line_end - p));
    if (tab && tab > p) {
      *tab = '\0';
      sqlite3_int64 id = strtoll(p, NULL, 10);
      sqlite3_bind_int64(ins, 1, id);
      sqlite3_bind_text(ins, 2, tab + 1, (int)(line_end - (tab + 1)), SQLITE_STATIC);
      sqlite3_step(ins);
      sqlite3_reset(ins);
      doc_count++;
    }
    p = nl ? (nl + 1) : end;
  }
  sqlite3_finalize(ins);
  sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);

  // Parse queries
  const char *queries[256];
  int q_count = 0;
  char *qp = qbuf;
  char *qend = qbuf + q_len;
  while (qp < qend && q_count < 256) {
    char *nl = (char *)memchr(qp, '\n', (size_t)(qend - qp));
    char *le = nl ? nl : qend;
    if (le > qp) {
      *le = '\0';
      queries[q_count++] = qp;
    }
    qp = nl ? (nl + 1) : qend;
  }

  sqlite3_stmt *sel = NULL;
  sqlite3_prepare_v2(
      db,
      "SELECT rowid FROM docs WHERE docs MATCH ? ORDER BY bm25(docs), rowid ASC LIMIT 20;",
      -1, &sel, NULL);

  long long total_hits = 0;
  for (int r = 0; r < reps; r++) {
    for (int qi = 0; qi < q_count; qi++) {
      sqlite3_bind_text(sel, 1, queries[qi], -1, SQLITE_STATIC);
      sqlite3_int64 ids[20];
      int n_hits = 0;
      while (sqlite3_step(sel) == SQLITE_ROW && n_hits < 20) {
        ids[n_hits++] = sqlite3_column_int64(sel, 0);
      }
      sqlite3_reset(sel);
      total_hits += n_hits;
      if (r == 0) {
        printf("q%d:%d", qi, n_hits);
        for (int hi = 0; hi < n_hits; hi++) {
          printf("%s%lld", hi == 0 ? " " : ",", (long long)ids[hi]);
        }
        putchar('\n');
      }
    }
  }
  printf("total_hits=%lld docs=%d reps=%d\n", total_hits, doc_count, reps);

  sqlite3_finalize(sel);
  sqlite3_close(db);
  free(corpus);
  free(qbuf);
  return 0;
}
