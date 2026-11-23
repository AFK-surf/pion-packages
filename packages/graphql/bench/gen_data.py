#!/usr/bin/env python3
"""Deterministic realistic GraphQL benchmark corpus generator.

Generates:
  1. Large GitHub/Linear-style Schema SDL (~2.5 MB)
  2. Complex Executable Query batch (200 distinct queries, run 100x = 20,000 queries)
"""

import sys
import os


def gen_sdl(path: str, modules: int = 120) -> int:
    parts = [
        '"""Root API Schema"""\n',
        "schema {\n  query: Query\n  mutation: Mutation\n  subscription: Subscription\n}\n\n",
        "scalar DateTime\nscalar JSON\nscalar Cursor\n\n",
        "directive @auth(requires: Role = MEMBER) repeatable on FIELD_DEFINITION | OBJECT\n",
        "directive @cacheControl(maxAge: Int = 60, scope: CacheScope = PUBLIC) on FIELD_DEFINITION | OBJECT\n\n",
        "enum Role { ADMIN MEMBER GUEST BOT }\n",
        "enum CacheScope { PUBLIC PRIVATE }\n",
        "enum SortDirection { ASC DESC }\n\n",
        "interface Node {\n  id: ID!\n  createdAt: DateTime!\n  updatedAt: DateTime!\n}\n\n",
        "interface Timestamped {\n  createdAt: DateTime!\n  updatedAt: DateTime!\n}\n\n",
    ]
    for m in range(modules):
        parts.append(
            f'"""\n  Domain entity Module{m} representing workspace resources.\n"""\n'
            f"type Module{m} implements Node & Timestamped @auth(requires: MEMBER) {{\n"
            f"  id: ID!\n"
            f"  createdAt: DateTime!\n"
            f"  updatedAt: DateTime!\n"
            f"  slug: String!\n"
            f"  title: String!\n"
            f"  description: String\n"
            f"  priority: Int!\n"
            f"  archived: Boolean!\n"
            f"  metadata: JSON\n"
            f"  items(first: Int = 25, after: Cursor, orderBy: SortDirection = DESC, filter: Module{m}Filter): Module{m}Connection! @cacheControl(maxAge: 30)\n"
            f"  comments(limit: Int = 50, includeDeleted: Boolean = false): [Module{m}Comment!]!\n"
            f"}}\n\n"
            f"type Module{m}Comment implements Node & Timestamped {{\n"
            f"  id: ID!\n"
            f"  createdAt: DateTime!\n"
            f"  updatedAt: DateTime!\n"
            f"  body: String!\n"
            f"  authorId: ID!\n"
            f"  reactions: [String!]!\n"
            f"}}\n\n"
            f"type Module{m}Edge {{\n"
            f"  cursor: Cursor!\n"
            f"  node: Module{m}!\n"
            f"}}\n\n"
            f"type Module{m}Connection {{\n"
            f"  edges: [Module{m}Edge!]!\n"
            f"  totalCount: Int!\n"
            f"  hasNextPage: Boolean!\n"
            f"}}\n\n"
            f"input Module{m}Filter {{\n"
            f"  search: String\n"
            f"  archived: Boolean = false\n"
            f"  minPriority: Int = 0\n"
            f"  tags: [String!] = []\n"
            f"}}\n\n"
            f"input CreateModule{m}Input {{\n"
            f"  title: String!\n"
            f"  slug: String!\n"
            f"  description: String = \"\"\n"
            f"  priority: Int = 1\n"
            f"}}\n\n"
            f"union Module{m}SearchResult = Module{m} | Module{m}Comment\n\n"
            f"extend type Query {{\n"
            f"  module{m}(id: ID!): Module{m}\n"
            f"  module{m}List(first: Int = 20, after: Cursor, filter: Module{m}Filter): Module{m}Connection!\n"
            f"}}\n\n"
            f"extend type Mutation {{\n"
            f"  createModule{m}(input: CreateModule{m}Input!): Module{m}! @auth(requires: ADMIN)\n"
            f"  archiveModule{m}(id: ID!): Boolean!\n"
            f"}}\n\n"
        )
    parts.append("type Query { viewerId: ID! }\n")
    parts.append("type Mutation { ping: Boolean! }\n")
    parts.append("type Subscription { events(channel: String!): JSON }\n")
    data = "".join(parts)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)
    return len(data.encode("utf-8"))


def gen_queries(path: str, count: int = 200) -> int:
    queries = []
    for i in range(count):
        if i % 10 == 9:
            # Intentionally invalid query (duplicate argument) so validator catches real errors
            q = (
                f"# query {i} with duplicate arg\n"
                f"query GetBoard{i}($id: ID!, $first: Int = 25) {{\n"
                f"  board(id: $id, id: $id, first: $first) {{\n"
                f"    id, title\n"
                f"    ...BoardMeta{i}\n"
                f"  }}\n"
                f"}}\n"
                f"fragment BoardMeta{i} on Board {{ createdAt updatedAt }}\n"
            )
        else:
            q = (
                f"# Workspace issue dashboard query {i}\n"
                f"query GetWorkspace{i}($org: String! = \"acme\", $first: Int = 25, $withComments: Boolean = true) @cached {{\n"
                f"  org: organization(slug: $org) {{\n"
                f"    id, name, plan\n"
                f"    teams(first: $first, note: \"\"\"\n      workspace {i}\n        summary\n    \"\"\", tag: \"\"\"  lead\"\"\", filter: {{ archived: false, minPriority: {i % 5}, tags: [\"core\", \"v2\"] }}) {{\n"
                f"      totalCount\n"
                f"      edges {{\n"
                f"        cursor\n"
                f"        node {{\n"
                f"          ...IssueCore{i}\n"
                f"          ... on ProjectIssue @include(if: $withComments) {{\n"
                f"            comments(limit: 10) {{ id body author {{ id name }} }}\n"
                f"          }}\n"
                f"        }}\n"
                f"      }}\n"
                f"    }}\n"
                f"  }}\n"
                f"}}\n"
                f"fragment IssueCore{i} on Issue {{\n"
                f"  id\n"
                f"  identifier\n"
                f"  title\n"
                f"  priority\n"
                f"  assignee {{ ...UserBrief{i} }}\n"
                f"}}\n"
                f"fragment UserBrief{i} on User {{ id name avatarUrl }}\n"
            )
        queries.append(q)
    # Delimit queries with a clean marker line `###QUERY###`
    data = "\n###QUERY###\n".join(queries)
    with open(path, "w", encoding="utf-8") as f:
        f.write(data)
    return len(data.encode("utf-8"))


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/pion-graphql-bench"
    sdl_modules = int(sys.argv[2]) if len(sys.argv) > 2 else 1400
    query_count = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    os.makedirs(out_dir, exist_ok=True)
    sdl_path = os.path.join(out_dir, "schema.graphql")
    q_path = os.path.join(out_dir, "queries.graphql")
    sdl_bytes = gen_sdl(sdl_path, sdl_modules)
    q_bytes = gen_queries(q_path, query_count)
    print(f"generated sdl={sdl_bytes} B ({sdl_path}), queries={q_bytes} B ({q_path})")
