#!/usr/bin/env python3
"""Deterministic SQL benchmark corpus generator for packages/sql."""
import sys

QUERIES = [
    # 1. CTE + multi-table JOIN + window function + subquery + ORDER BY NULLS LAST + LIMIT/OFFSET
    (
        "WITH active_users AS ("
        "SELECT id, email, region FROM users WHERE active = TRUE AND deleted_at IS NULL"
        ") "
        "SELECT u.id, u.email, o.order_id, o.total, "
        "ROW_NUMBER() OVER (PARTITION BY u.region ORDER BY o.total DESC) AS region_rank, "
        "SUM(o.total) OVER (PARTITION BY u.id ORDER BY o.created_at ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total "
        "FROM active_users u "
        "INNER JOIN orders o ON u.id = o.user_id "
        "LEFT JOIN payments p ON o.order_id = p.order_id "
        "WHERE o.total >= 100 AND EXISTS (SELECT 1 FROM shipments s WHERE s.order_id = o.order_id) "
        "ORDER BY o.total DESC NULLS LAST LIMIT 50 OFFSET 10"
    ),
    # 2. Recursive CTE + UNION ALL + GROUP BY + HAVING
    (
        "WITH RECURSIVE org_tree (id, parent_id, depth) AS ("
        "SELECT id, parent_id, 0 FROM departments WHERE parent_id IS NULL "
        "UNION ALL "
        "SELECT d.id, d.parent_id, t.depth + 1 FROM departments d INNER JOIN org_tree t ON d.parent_id = t.id"
        ") "
        "SELECT t.depth, COUNT(*) AS dept_cnt FROM org_tree t "
        "GROUP BY t.depth HAVING COUNT(*) > 1 ORDER BY t.depth ASC"
    ),
    # 3. Complex Pratt expressions: CASE, CAST, JSON operators, ILIKE, BETWEEN, IN
    (
        "SELECT id, "
        "CASE WHEN score >= 90 THEN 'A' WHEN score >= 80 THEN 'B' ELSE 'C' END AS grade, "
        "CAST(amount AS NUMERIC(12, 2)) AS amt, "
        "payload -> 'meta' ->> 'source' AS src "
        "FROM events "
        "WHERE name NOT ILIKE '%bot%' AND score BETWEEN 10 AND 100 "
        "AND status IN ('open', 'pending', 'review') AND created_at IS NOT NULL"
    ),
    # 4. Aggregate with DISTINCT and FILTER (WHERE ...)
    (
        "SELECT tenant_id, "
        "COUNT(DISTINCT user_id) FILTER (WHERE paid = TRUE) AS paying_users, "
        "SUM(amount) FILTER (WHERE refunded = FALSE) AS net_rev "
        "FROM invoices WHERE fiscal_year = 2026 GROUP BY tenant_id ORDER BY net_rev DESC"
    ),
    # 5. INSERT ... VALUES ... ON CONFLICT DO UPDATE ... RETURNING
    (
        "INSERT INTO accounts (id, email, balance, updated_at) "
        "VALUES ($1, $2, 0, $3), ($4, $5, 100, $6) "
        "ON CONFLICT (email) DO UPDATE SET balance = excluded.balance, updated_at = excluded.updated_at "
        "WHERE accounts.locked = FALSE RETURNING id, email"
    ),
    # 6. UPDATE ... SET ... FROM ... WHERE ... RETURNING
    (
        "UPDATE orders SET status = 'fulfilled', shipped_at = $1 "
        "FROM shipments s WHERE orders.id = s.order_id AND s.delivered = TRUE "
        "RETURNING orders.id, status"
    ),
    # 7. DELETE ... WHERE ... RETURNING
    (
        "DELETE FROM sessions WHERE expires_at < $1 AND revoked = TRUE RETURNING id"
    ),
    # 8. DDL: CREATE TABLE with constraints & FK
    (
        "CREATE TABLE IF NOT EXISTS line_items ("
        "id BIGSERIAL PRIMARY KEY, "
        "order_id BIGINT NOT NULL REFERENCES orders (id) ON DELETE CASCADE, "
        "sku VARCHAR(64) NOT NULL, "
        "qty INTEGER NOT NULL CHECK (qty > 0), "
        "unit_price NUMERIC(10, 2) DEFAULT 0.00, "
        "tags TEXT[], "
        "CONSTRAINT uq_order_sku UNIQUE (order_id, sku)"
        ")"
    ),
    # 9. DDL: CREATE UNIQUE INDEX with partial predicate
    (
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_user_status "
        "ON orders (user_id ASC, created_at DESC) WHERE deleted_at IS NULL"
    ),
    # 10. DDL: ALTER TABLE
    (
        "ALTER TABLE line_items ADD COLUMN note TEXT DEFAULT ''"
    ),
]


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: gen_data.py <queries|script> <out_path> [repeats]\n")
        return 1
    mode = sys.argv[1]
    out_path = sys.argv[2]
    if mode == "queries":
        with open(out_path, "w", encoding="utf-8") as f:
            for q in QUERIES:
                f.write(q + "\n")
        return 0
    if mode == "script":
        repeats = int(sys.argv[3]) if len(sys.argv) > 3 else 400
        block = ";\n".join(QUERIES) + ";\n"
        with open(out_path, "w", encoding="utf-8") as f:
            for _ in range(repeats):
                f.write(block)
        return 0
    sys.stderr.write(f"unknown mode: {mode}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
