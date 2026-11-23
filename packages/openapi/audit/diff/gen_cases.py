#!/usr/bin/env python3
"""Generate the red-team differential corpus for packages/openapi vs Go kin-openapi v0.131.0.

Every case: {"id", "spec" (JSON/YAML text), "ops": [...], "expect": "<spec verdict line part>"|null, "why": str}
`expect` is the OpenAPI 3.0.3 / 3.1.0 (+ JSON Schema / RFC 3986 / RFC 9110) verdict where the spec defines one,
written in the same `load=..\tvalid=..\t<ops>` form the drivers print (a field ending in `*` is a prefix wildcard).
Usage: gen_cases.py > cases.jsonl
"""
import json
import sys

CASES = []


def spec30(paths, components=None, extra=None, version="3.0.3"):
    d = {"openapi": version, "info": {"title": "t", "version": "1"}, "paths": paths}
    if components is not None:
        d["components"] = components
    if extra:
        d.update(extra)
    return json.dumps(d, separators=(",", ":"))


def spec31(paths, components=None, extra=None):
    return spec30(paths, components, extra, version="3.1.0")


def ok_resp(schema=None):
    r = {"description": "ok"}
    if schema is not None:
        r["content"] = {"application/json": {"schema": schema}}
    return {"200": r}


def op(op_id, params=None, body=None, responses=None, **kw):
    o = {"operationId": op_id, "responses": responses or ok_resp()}
    if params is not None:
        o["parameters"] = params
    if body is not None:
        o["requestBody"] = body
    o.update(kw)
    return o


def pparam(name, schema=None, **kw):
    p = {"name": name, "in": "path", "required": True, "schema": schema or {"type": "string"}}
    p.update(kw)
    return p


def qparam(name, schema, required=False, **kw):
    p = {"name": name, "in": "query", "required": required, "schema": schema}
    p.update(kw)
    return p


def hparam(name, schema, required=False, **kw):
    p = {"name": name, "in": "header", "required": required, "schema": schema}
    p.update(kw)
    return p


def route(m, p):
    return {"k": "route", "m": m, "p": p}


def req(m, p, q=None, h=None, c=None, ct=None, b=None):
    return {"k": "req", "m": m, "p": p, "q": q or [], "h": h or [], "c": c or [], "ct": ct, "b": b}


def resp(m, p, st, rb=None, rct="application/json", rh=None):
    return {"k": "resp", "m": m, "p": p, "q": [], "h": [], "c": [], "ct": None, "b": None,
            "st": st, "rb": rb, "rct": rct, "rh": rh or []}


def case(cid, spec, ops, expect=None, why=""):
    CASES.append({"id": cid, "spec": spec, "ops": ops, "expect": expect, "why": why})


def jbody(schema, required=True):
    return {"required": required, "content": {"application/json": {"schema": schema}}}


# ---------------------------------------------------------------------------
# 1. router
# ---------------------------------------------------------------------------
users = spec30({
    "/users": {"get": op("listUsers")},
    "/users/me": {"get": op("me")},
    "/users/{id}": {"get": op("getUser", [pparam("id")]), "delete": op("delUser", [pparam("id")])},
    "/files/{name}.{ext}": {"get": op("file", [pparam("name"), pparam("ext")])},
})
case("route.static_vs_param", users,
     [route("GET", "/users/me"), route("GET", "/users/42"), route("DELETE", "/users/me")],
     "load=ok\tvalid=ok\top:me|op:getUser,id=42|op:delUser,id=me",
     "static beats template; DELETE /users/me falls back to the template (gorilla & spec)")
case("route.trailing_slash", users, [route("GET", "/users/"), route("GET", "/users/42/")],
     "load=ok\tvalid=ok\t404|404",
     "OpenAPI paths are matched literally: '/users/' is not '/users' (RFC 3986 distinct paths)")
case("route.empty_segment", users, [route("GET", "//users"), route("GET", "/users//42"), route("GET", "/users/42//")],
     "load=ok\tvalid=ok\t404|404|404", "empty path segments are significant; '//' must not collapse")
case("route.pct_slash", users, [route("GET", "/users/a%2Fb")],
     "load=ok\tvalid=ok\top:getUser,id=a/b", "%2F stays inside one segment and decodes to '/' in the value")
case("route.pct_dotdot", users, [route("GET", "/users/%2e%2e"), route("GET", "/users/../users/me")],
     "load=ok\tvalid=ok\top:getUser,id=..|*", "encoded dot-segments are data (RFC 3986 6.2.2.3)")
case("route.pct_utf8", users, [route("GET", "/users/%E4%B8%AD%E6%96%87"), route("GET", "/users/caf%C3%A9")],
     "load=ok\tvalid=ok\top:getUser,id=中文|op:getUser,id=café",
     "percent-encoded UTF-8 must decode to the UTF-8 text (RFC 3986 2.5)")
case("route.raw_utf8_with_pct", users, [route("GET", "/users/中%20文")],
     "load=ok\tvalid=ok\top:getUser,id=中 文", "raw non-ASCII code points must survive percent-decoding")
case("route.query_fragment", users, [route("GET", "/users/42?x=1"), route("GET", "/users/me#frag")],
     None, "query string / fragment stripping")
case("route.inline", users, [route("GET", "/files/report.pdf"), route("GET", "/files/a.b.c"), route("GET", "/files/.pdf")],
     None, "inline template split: name/ext greedy vs lazy")
case("route.405", users, [route("POST", "/users/42"), route("PATCH", "/users")],
     "load=ok\tvalid=ok\t405|405", "known path, unknown method")
case("route.head_options", users, [route("HEAD", "/users"), route("OPTIONS", "/users")],
     "load=ok\tvalid=ok\t405|405", "HEAD is not implied by GET in OpenAPI")
case("route.method_case", users, [{"k": "route", "m": "get", "p": "/users"}], None,
     "HTTP methods are case-sensitive tokens (RFC 9110 9.1)")
case("route.deep_path", users, [route("GET", "/users" + "/x" * 5000)], "load=ok\tvalid=ok\t404", "deep path DoS")
servers = spec30({"/users": {"get": op("listUsers")}}, extra={"servers": [{"url": "https://api.example.com/v1"}]})
case("route.server_base_path", servers, [route("GET", "/v1/users"), route("GET", "/users")],
     "load=ok\tvalid=ok\top:listUsers|404",
     "paths are relative to the server URL (OAS 3.0.3 4.7.9: 'The path is appended to the URL from the Server Object')")
servers_rel = spec30({"/users": {"get": op("listUsers")}}, extra={"servers": [{"url": "/api"}]})
case("route.server_relative", servers_rel, [route("GET", "/api/users"), route("GET", "/users")],
     "load=ok\tvalid=ok\top:listUsers|404", "relative server URL is a base-path prefix")
servers_tpl = spec30({"/users": {"get": op("listUsers")}},
                     extra={"servers": [{"url": "/{ver}", "variables": {"ver": {"default": "v2", "enum": ["v1", "v2"]}}}]})
case("route.server_template", servers_tpl, [route("GET", "/v1/users"), route("GET", "/v2/users")],
     "load=ok\tvalid=ok\top:listUsers*|op:listUsers*", "server variables")
amb = spec30({"/a/{x}/b": {"get": op("ax", [pparam("x")])}, "/a/{y}/b": {"post": op("ay", [pparam("y")])}})
case("route.ambiguous_templates", amb, [route("GET", "/a/1/b"), route("POST", "/a/1/b")],
     "load=ok\tvalid=err\t*|*", "OAS 3.0.3 4.7.8: templated paths with the same hierarchy but different names are identical/invalid")
mixed = spec30({"/a/{x}/c": {"get": op("axc", [pparam("x")])}, "/a/b/{y}": {"get": op("aby", [pparam("y")])}})
case("route.backtrack", mixed, [route("GET", "/a/b/c"), route("GET", "/a/z/c"), route("GET", "/a/b/z")], None,
     "static prefix must backtrack into template branch")
case("route.param_names_remap", spec30({
    "/u/{uid}/p": {"get": op("up", [pparam("uid")])},
    "/u/{name}/q": {"get": op("uq", [pparam("name")])}}),
    [route("GET", "/u/1/p"), route("GET", "/u/2/q")],
    "load=ok\tvalid=ok\top:up,uid=1|op:uq,name=2", "same trie node, different param names per route")

# ---------------------------------------------------------------------------
# 2. parameters
# ---------------------------------------------------------------------------
def pspec(params, version="3.0.3"):
    return spec30({"/x": {"get": op("x", params)}}, version=version)


intq = pspec([qparam("n", {"type": "integer", "minimum": 0, "maximum": 100})])
for v, exp, why in [("5", "ok", "plain"), ("01", "*", "leading zero (kin ParseInt base0 = octal)"),
                    ("0x1F", "*", "hex (kin base0 accepts)"), ("1e1", "*", "exponent form"),
                    ("1.0", "*", "1.0 is an integer per JSON Schema"), (" 5", "*", "leading space"),
                    ("5 ", "*", "trailing space"), ("", "*", "empty value"), ("-0", "ok", "negative zero"),
                    ("abc", "err", "not a number"), ("101", "err", "max"), ("9223372036854775808", "err", "> int64"),
                    ("1_0", "*", "underscore (kin base0)")]:
    case(f"param.int[{v!r}]", intq, [req("GET", "/x", q=[["n", v]])],
         None if exp == "*" else f"load=ok\tvalid=ok\t{exp}", why)
numq = pspec([qparam("f", {"type": "number"})])
for v in ["NaN", "Inf", "-Infinity", "1e400", "0x10", ".5", "5."]:
    case(f"param.num[{v!r}]", numq, [req("GET", "/x", q=[["f", v]])], None, "number coercion edge")
boolq = pspec([qparam("b", {"type": "boolean"})])
for v in ["true", "True", "TRUE", "1", "t", "yes", ""]:
    case(f"param.bool[{v!r}]", boolq, [req("GET", "/x", q=[["b", v]])],
         "load=ok\tvalid=ok\tok" if v == "true" else None, "boolean coercion")
reqq = pspec([qparam("n", {"type": "integer"}, required=True)])
case("param.required_missing", reqq, [req("GET", "/x")], "load=ok\tvalid=ok\terr", "required query absent")
case("param.required_empty", reqq, [req("GET", "/x", q=[["n", ""]])], "load=ok\tvalid=ok\terr",
     "empty value for required integer without allowEmptyValue")
aev = pspec([qparam("s", {"type": "string", "minLength": 1}, allowEmptyValue=True)])
case("param.allowEmptyValue", aev, [req("GET", "/x", q=[["s", ""]])], "load=ok\tvalid=ok\tok",
     "OAS 3.0.3: allowEmptyValue lets ?s= pass")
arrq = pspec([qparam("tag", {"type": "array", "items": {"type": "string"}, "maxItems": 2})])
case("param.array_explode", arrq, [req("GET", "/x", q=[["tag", "a"], ["tag", "b"]]),
                                    req("GET", "/x", q=[["tag", "a"], ["tag", "b"], ["tag", "c"]])],
     "load=ok\tvalid=ok\tok|err", "form+explode repeats the key")
arrq_ne = pspec([qparam("tag", {"type": "array", "items": {"type": "integer"}}, style="form", explode=False)])
case("param.array_form_noexplode", arrq_ne, [req("GET", "/x", q=[["tag", "1,2"]]), req("GET", "/x", q=[["tag", "1,x"]])],
     "load=ok\tvalid=ok\tok|err", "form, explode=false -> comma list")
pipe = pspec([qparam("tag", {"type": "array", "items": {"type": "integer"}}, style="pipeDelimited", explode=False)])
case("param.array_pipe", pipe, [req("GET", "/x", q=[["tag", "1|2"]])], "load=ok\tvalid=ok\tok", "pipeDelimited")
objq = pspec([qparam("filter", {"type": "object", "properties": {"a": {"type": "integer"}}}, style="deepObject", explode=True)])
case("param.deepObject", objq, [req("GET", "/x", q=[["filter[a]", "1"]]), req("GET", "/x", q=[["filter[a]", "x"]])],
     "load=ok\tvalid=ok\tok|err", "deepObject style (OAS 3.0.3 4.7.12.4)")
objform = pspec([qparam("o", {"type": "object", "properties": {"a": {"type": "integer"}}}, style="form", explode=False)])
case("param.object_form", objform, [req("GET", "/x", q=[["o", "a,1"]]), req("GET", "/x", q=[["o", "a,x"]])],
     "load=ok\tvalid=ok\tok|err", "form object explode=false: o=a,1")
label = spec30({"/x/{id}": {"get": op("x", [pparam("id", {"type": "integer"}, style="label")])}})
case("param.path_label", label, [req("GET", "/x/.5")], "load=ok\tvalid=ok\tok", "label style path param")
matrix = spec30({"/x/{id}": {"get": op("x", [pparam("id", {"type": "integer"}, style="matrix")])}})
case("param.path_matrix", matrix, [req("GET", "/x/;id=5")], "load=ok\tvalid=ok\tok", "matrix style path param")
hdr = pspec([hparam("X-Rate", {"type": "integer", "maximum": 10}, required=True)])
case("param.header_case", hdr, [req("GET", "/x", h=[["x-rate", "5"]]), req("GET", "/x", h=[["X-RATE", "50"]])],
     "load=ok\tvalid=ok\tok|err", "header names are case-insensitive (RFC 9110 5.1)")
hdr_arr = pspec([hparam("X-Ids", {"type": "array", "items": {"type": "integer"}})])
case("param.header_array", hdr_arr, [req("GET", "/x", h=[["X-Ids", "1,2,3"]]), req("GET", "/x", h=[["X-Ids", "1,b"]])],
     "load=ok\tvalid=ok\tok|err", "simple-style array header")
ck = pspec([{"name": "sid", "in": "cookie", "required": True, "schema": {"type": "string", "minLength": 4}}])
case("param.cookie", ck, [req("GET", "/x", c=[["sid", "abcd"]]), req("GET", "/x", c=[["sid", "ab"]]), req("GET", "/x")],
     "load=ok\tvalid=ok\tok|err|err", "cookie param")
content_param = pspec([{"name": "q", "in": "query", "required": True,
                        "content": {"application/json": {"schema": {"type": "object", "required": ["a"]}}}}])
case("param.content_json", content_param, [req("GET", "/x", q=[["q", '{"a":1}']]), req("GET", "/x", q=[["q", '{"b":1}']])],
     "load=ok\tvalid=ok\tok|err", "parameter with `content` (OAS 3.0.3 4.7.12) must be validated")
bad_in = pspec([{"name": "q", "in": "body", "schema": {"type": "string"}}])
case("param.bad_in", bad_in, [route("GET", "/x")], "load=*\tvalid=err\t*", "in: body is not an OpenAPI 3 location")
override = spec30({"/x/{id}": {"parameters": [pparam("id", {"type": "integer"}), qparam("v", {"type": "integer"}, required=True)],
                               "get": op("x", [qparam("v", {"type": "string"}, required=False)])}})
case("param.override", override, [req("GET", "/x/1"), req("GET", "/x/1", q=[["v", "abc"]]), req("GET", "/x/z", q=[["v", "1"]])],
     "load=ok\tvalid=ok\tok|ok|err", "operation-level (name,in) overrides PathItem-level")
dangling_param = pspec([{"$ref": "#/components/parameters/Nope"}])
case("param.dangling_ref", dangling_param, [req("GET", "/x")], "load=err\tvalid=-\t-", "dangling parameter $ref")

# ---------------------------------------------------------------------------
# 3. bodies, readOnly/writeOnly, nullable, content types
# ---------------------------------------------------------------------------
pet = {"type": "object", "required": ["id", "name"],
       "properties": {"id": {"type": "integer", "readOnly": True}, "name": {"type": "string"},
                      "secret": {"type": "string", "writeOnly": True}}}
ro = spec30({"/pets": {"post": op("createPet", body=jbody({"$ref": "#/components/schemas/Pet"}),
                                  responses=ok_resp({"$ref": "#/components/schemas/Pet"}))}},
            {"schemas": {"Pet": pet}})
case("body.readonly_required_omitted", ro, [req("POST", "/pets", ct="application/json", b='{"name":"rex"}')],
     "load=ok\tvalid=ok\tok", "OAS 3.0.3 4.7.24: readOnly required props apply only to responses")
case("body.readonly_sent_in_request", ro, [req("POST", "/pets", ct="application/json", b='{"id":1,"name":"rex"}')],
     None, "readOnly property sent in request (SHOULD NOT be sent; kin rejects)")
case("body.writeonly_in_response", ro, [resp("POST", "/pets", 200, rb='{"id":1,"name":"rex","secret":"x"}')],
     None, "writeOnly property returned in response (kin rejects)")
case("body.writeonly_required_omitted_resp", spec30(
    {"/p": {"get": op("p", responses=ok_resp({"type": "object", "required": ["pw"],
                                              "properties": {"pw": {"type": "string", "writeOnly": True}}}))}}),
    [resp("GET", "/p", 200, rb='{}')], "load=ok\tvalid=ok\tok", "writeOnly required props apply only to requests")
nul = spec30({"/n": {"post": op("n", body=jbody({"type": "object", "properties": {
    "e": {"type": "string", "enum": ["a", "b"], "nullable": True},
    "r": {"$ref": "#/components/schemas/S"}, "a": {"allOf": [{"$ref": "#/components/schemas/S"}], "nullable": True}}}))}},
    {"schemas": {"S": {"type": "string"}}})
case("body.nullable_enum", nul, [req("POST", "/n", ct="application/json", b='{"e":null}')], None,
     "nullable+enum without null in the enum (OAI clarification: null allowed; kin allows)")
case("body.nullable_ref_sibling30", nul, [req("POST", "/n", ct="application/json", b='{"r":null}')],
     "load=ok\tvalid=ok\terr", "3.0 $ref ignores siblings, S is not nullable")
case("body.nullable_allof", nul, [req("POST", "/n", ct="application/json", b='{"a":null}'), req("POST", "/n", ct="application/json", b='{"a":1}')],
     "load=ok\tvalid=ok\tok|err", "nullable + allOf wrapper")
excl = spec30({"/e": {"post": op("e", body=jbody({"type": "number", "minimum": 0, "exclusiveMinimum": True, "maximum": 10, "exclusiveMaximum": True}))}})
case("body.exclusive_bool30", excl, [req("POST", "/e", ct="application/json", b=b) for b in ["0", "0.1", "10", "9.9"]],
     "load=ok\tvalid=ok\terr|ok|err|ok", "3.0 boolean exclusiveMinimum/Maximum")
ctx = spec30({"/c": {"post": op("c", body={"required": True, "content": {
    "application/json": {"schema": {"type": "object", "required": ["a"]}},
    "application/x-www-form-urlencoded": {"schema": {"type": "object", "required": ["a"], "properties": {"a": {"type": "integer"}}}},
    "text/plain": {"schema": {"type": "string", "maxLength": 3}}}})}})
case("body.ct_params", ctx, [req("POST", "/c", ct="application/json; charset=utf-8", b='{"a":1}'),
                             req("POST", "/c", ct="Application/JSON", b='{}')], "load=ok\tvalid=ok\tok|err", "media-type params / case")
case("body.form_urlencoded", ctx, [req("POST", "/c", ct="application/x-www-form-urlencoded", b="a=1"),
                                   req("POST", "/c", ct="application/x-www-form-urlencoded", b="b=1"),
                                   req("POST", "/c", ct="application/x-www-form-urlencoded", b="a=x")],
     "load=ok\tvalid=ok\tok|err|err", "form bodies must be validated against their schema")
case("body.text_plain", ctx, [req("POST", "/c", ct="text/plain", b="abcdef")], "load=ok\tvalid=ok\terr", "text/plain maxLength")
case("body.missing_ct", ctx, [req("POST", "/c", b='{"a":1}')], None, "no Content-Type")
case("body.required_missing", ctx, [req("POST", "/c", ct="application/json")], "load=ok\tvalid=ok\terr", "required body absent")
case("body.required_empty", ctx, [req("POST", "/c", ct="application/json", b="")], "load=ok\tvalid=ok\terr", "required body empty")
case("body.unknown_ct", ctx, [req("POST", "/c", ct="application/xml", b="<a/>")], "load=ok\tvalid=ok\terr", "undeclared media type")
problem = spec30({"/c": {"post": op("c", body=jbody({"type": "object", "required": ["a"]}))}})
case("body.problem_json", problem, [req("POST", "/c", ct="application/problem+json", b='{}')], None,
     "+json suffix is NOT application/json (only application/json declared)")
wild = spec30({"/c": {"post": op("c", body={"content": {"application/*": {"schema": {"type": "object", "required": ["a"]}}}})}})
case("body.wildcard", wild, [req("POST", "/c", ct="application/json", b='{}'), req("POST", "/c", ct="application/merge-patch+json", b='{}')],
     "load=ok\tvalid=ok\terr|err", "type/* wildcard applies the schema")
big = spec30({"/c": {"post": op("c", body=jbody({"type": "object", "properties": {"n": {"type": "integer"}}}))}})
case("body.bigint", big, [req("POST", "/c", ct="application/json", b='{"n":9007199254740993}'),
                          req("POST", "/c", ct="application/json", b='{"n":1e400}')], None, "big integers")
case("body.dup_keys", spec30({"/c": {"post": op("c", body=jbody({"type": "object", "properties": {"n": {"type": "integer"}}}))}}),
     [req("POST", "/c", ct="application/json", b='{"n":"x","n":1}')], None, "duplicate JSON keys")
ex_ref = spec30({"/c": {"post": op("c", body=jbody({"type": "object", "example": {"$ref": "#/not/a/ref"},
                                                     "default": {"$ref": "#/also/not"}}))}})
case("body.literal_ref_in_example", ex_ref, [req("POST", "/c", ct="application/json", b='{}')],
     "load=ok\tvalid=*\tok", "`example`/`default` are literal data, a \"$ref\" key there is not a Reference Object")
enum_obj = spec30({"/c": {"post": op("c", body=jbody({"enum": [{"nullable": True, "type": "string"}]}))}})
case("body.literal_enum_normalized", enum_obj, [req("POST", "/c", ct="application/json", b='{"nullable":true,"type":"string"}')],
     "load=ok\tvalid=ok\tok", "enum members are data; 3.0 nullable rewrite must not touch them")
prop_named = spec30({"/c": {"post": op("c", body=jbody({"type": "object", "properties": {
    "nullable": {"type": "boolean"}, "minimum": {"type": "integer"}, "type": {"type": "string"}}, "required": ["type"]}))}})
case("body.props_named_like_keywords", prop_named, [req("POST", "/c", ct="application/json", b='{"type":"x","nullable":true,"minimum":3}')],
     "load=ok\tvalid=ok\tok", "property names equal to keywords")

# 3.1 specifics
s31 = spec31({"/c": {"post": op("c", body=jbody({"$ref": "#/components/schemas/A", "required": ["b"]}))}},
             {"schemas": {"A": {"type": "object", "required": ["a"]}}})
case("body31.ref_sibling_and", s31, [req("POST", "/c", ct="application/json", b='{"b":1}'),
                                     req("POST", "/c", ct="application/json", b='{"a":1,"b":1}')],
     "load=*\tvalid=*\terr|ok", "2020-12: $ref and sibling keywords both apply (AND), not override")
s31n = spec31({"/c": {"post": op("c", body=jbody({"type": ["string", "null"], "exclusiveMinimum": 5}))}})
case("body31.type_array_null", s31n, [req("POST", "/c", ct="application/json", b="null")], "load=*\tvalid=*\tok", "3.1 type: [string, null]")
wh = json.dumps({"openapi": "3.1.0", "info": {"title": "t", "version": "1"},
                 "webhooks": {"newPet": {"post": {"requestBody": {"content": {"application/json": {"schema": {"type": "object"}}}},
                                                  "responses": {"200": {"description": "ok"}}}}}})
case("doc31.webhooks_only", wh, [], "load=*\tvalid=ok\t", "3.1 doc with only webhooks is valid")

# ---------------------------------------------------------------------------
# 4. responses
# ---------------------------------------------------------------------------
rs = spec30({"/r": {"get": op("r", responses={
    "201": {"description": "c", "content": {"application/json": {"schema": {"type": "integer"}}}},
    "2XX": {"description": "x", "content": {"application/json": {"schema": {"type": "string"}}}},
    "default": {"description": "d", "content": {"application/json": {"schema": {"type": "boolean"}}}}})}})
case("resp.status_order", rs, [resp("GET", "/r", 201, "1"), resp("GET", "/r", 202, '"s"'), resp("GET", "/r", 500, "true"),
                               resp("GET", "/r", 201, '"s"'), resp("GET", "/r", 202, "1")],
     "load=ok\tvalid=ok\tok|ok|ok|err|err", "exact > NXX > default")
rh = spec30({"/r": {"get": op("r", responses={"200": {"description": "ok", "headers": {
    "X-Rate": {"required": True, "schema": {"type": "integer"}}, "X-Id": {"schema": {"type": "string", "maxLength": 2}}}}})}})
case("resp.headers", rh, [resp("GET", "/r", 200, rh=[["x-rate", "1"]]), resp("GET", "/r", 200),
                          resp("GET", "/r", 200, rh=[["X-Rate", "a"]]), resp("GET", "/r", 200, rh=[["X-Rate", "1"], ["X-Id", "abc"]])],
     "load=ok\tvalid=ok\tok|err|err|err", "response headers")
case("resp.undocumented_ct", spec30({"/r": {"get": op("r", responses=ok_resp({"type": "object"}))}}),
     [resp("GET", "/r", 200, "<a/>", rct="application/xml")], "load=ok\tvalid=ok\terr", "undeclared response media type")

# ---------------------------------------------------------------------------
# 5. static validation
# ---------------------------------------------------------------------------
case("doc.dup_opid", spec30({"/a": {"get": op("same")}, "/b": {"get": op("same")}}), [], "load=*\tvalid=err\t", "duplicate operationId")
case("doc.undeclared_path_param", spec30({"/a/{id}": {"get": op("a")}}), [], "load=*\tvalid=err\t", "template param not declared")
case("doc.extra_path_param", spec30({"/a": {"get": op("a", [pparam("id")])}}), [], "load=*\tvalid=err\t", "path param not in template")
case("doc.path_param_not_required", spec30({"/a/{id}": {"get": op("a", [{"name": "id", "in": "path", "schema": {"type": "string"}}])}}),
     [], "load=*\tvalid=err\t", "path params MUST be required")
case("doc.bad_method_key", spec30({"/a": {"GET": op("a"), "fetch": op("b")}}), [], "load=*\tvalid=err\t", "invalid method keys")
case("doc.no_paths30", json.dumps({"openapi": "3.0.3", "info": {"title": "t", "version": "1"}}), [], "load=*\tvalid=err\t", "3.0 requires paths")
case("doc.bad_status", spec30({"/a": {"get": op("a", responses={"2X0": {"description": "x"}})}}), [], "load=*\tvalid=err\t", "bad status key")
case("doc.no_leading_slash", spec30({"a": {"get": op("a")}}), [], "load=*\tvalid=err\t", "path must start with '/'")
case("doc.bad_schema_type", spec30({"/a": {"get": op("a", responses=ok_resp({"type": "strin"}))}}), [], "load=*\tvalid=err\t",
     "schema with invalid type keyword")
case("doc.bad_regex", spec30({"/a": {"get": op("a", [qparam("q", {"type": "string", "pattern": "(["})])}}), [], "load=*\tvalid=err\t",
     "invalid regex pattern in schema")
case("doc.swagger2", json.dumps({"swagger": "2.0", "info": {"title": "t", "version": "1"}, "paths": {}}), [], "load=err\tvalid=-\t-", "Swagger 2.0")
case("doc.yaml", "openapi: 3.0.3\ninfo: {title: t, version: '1'}\npaths:\n  /a:\n    get:\n      operationId: a\n      responses:\n        '200': {description: ok}\n",
     [route("GET", "/a")], "load=ok\tvalid=ok\top:a", "YAML doc")
case("doc.yaml_int_status", "openapi: 3.0.3\ninfo: {title: t, version: '1'}\npaths:\n  /a:\n    get:\n      operationId: a\n      responses:\n        200: {description: ok}\n",
     [route("GET", "/a")], None, "YAML integer response key")
case("doc.yaml_anchor", "openapi: 3.0.3\ninfo: {title: t, version: '1'}\nx-r: &r {'200': {description: ok}}\npaths:\n  /a:\n    get:\n      operationId: a\n      responses: *r\n",
     [route("GET", "/a")], "load=ok\tvalid=ok\top:a", "YAML anchor/alias")
ptr = spec30({"/a": {"get": op("a", responses=ok_resp({"$ref": "#/components/schemas/My%20Type"}))},
              "/b": {"get": op("b", responses=ok_resp({"$ref": "#/components/schemas/a~1b"}))},
              "/c": {"get": op("c", responses=ok_resp({"$ref": "#/components/schemas/t~0x"}))},
              "/d": {"get": op("d", responses=ok_resp({"$ref": "#/components/schemas/%E4%B8%AD"}))}},
             {"schemas": {"My Type": {"type": "integer"}, "a/b": {"type": "integer"}, "t~x": {"type": "integer"}, "中": {"type": "integer"}}})
case("ref.pointer_escapes", ptr, [resp("GET", "/a", 200, '"s"'), resp("GET", "/b", 200, '"s"'), resp("GET", "/c", 200, '"s"'),
                                  resp("GET", "/d", 200, '"s"')],
     "load=ok\tvalid=ok\terr|err|err|err", "RFC 6901 + URI fragment percent-encoding (incl. UTF-8)")
case("ref.external", spec30({"/a": {"get": op("a", responses=ok_resp({"$ref": "other.yaml#/X"}))}}), [], None, "external $ref")
case("ref.self_cycle", spec30({"/a": {"get": op("a", responses=ok_resp({"$ref": "#/components/schemas/A"}))}},
                              {"schemas": {"A": {"$ref": "#/components/schemas/A"}}}), [], "load=*\tvalid=err\t*", "A -> A alias")
case("ref.recursive_ok", spec30({"/a": {"get": op("a", responses=ok_resp({"$ref": "#/components/schemas/N"}))}},
                                {"schemas": {"N": {"type": "object", "properties": {"kids": {"type": "array", "items": {"$ref": "#/components/schemas/N"}}}}}}),
     [resp("GET", "/a", 200, '{"kids":[{"kids":[]}]}'), resp("GET", "/a", 200, '{"kids":[{"kids":1}]}')],
     "load=ok\tvalid=ok\tok|err", "recursive schema")
# two distinct recursive schemas whose names sanitize to the same $defs key
coll = spec30({"/a": {"post": op("a", body=jbody({"type": "object", "properties": {
    "x": {"$ref": "#/components/schemas/a.b"}, "y": {"$ref": "#/components/schemas/a_b"}}}))}},
    {"schemas": {"a.b": {"type": "object", "properties": {"s": {"type": "string"}, "n": {"$ref": "#/components/schemas/a.b"}}},
                 "a_b": {"type": "object", "properties": {"i": {"type": "integer"}, "n": {"$ref": "#/components/schemas/a_b"}}}}})
case("ref.defs_name_collision", coll, [req("POST", "/a", ct="application/json", b='{"y":{"i":1,"n":{"i":2}}}'),
                                        req("POST", "/a", ct="application/json", b='{"y":{"i":1,"n":{"i":"str"}}}')],
     "load=ok\tvalid=ok\tok|err", "recursive schemas 'a.b' and 'a_b' must not share one hoisted $defs entry")

if __name__ == "__main__":
    out = sys.stdout
    for c in CASES:
        out.write(json.dumps(c, ensure_ascii=False, separators=(",", ":")) + "\n")
