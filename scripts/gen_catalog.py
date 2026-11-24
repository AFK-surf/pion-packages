#!/usr/bin/env python3
"""Generate / verify the machine-readable package catalog `catalog.json`.

Zero external dependencies (Python 3.8+ standard library only).

Usage:
  python3 scripts/gen_catalog.py             # (re)write catalog.json at repo root
  python3 scripts/gen_catalog.py --check     # exit 1 unless catalog.json is byte-identical
  python3 scripts/gen_catalog.py --skill-md  # print a grouped Markdown cheat sheet to stdout

Authoritative sources:
  index/<name>.toml          name / version / git / tag / subdir (published packages)
  <subdir>/pion.toml         must agree on name + version; [dependencies] -> deps
  <subdir>/wasm_smoke/       presence of wasm_smoke/pion.toml -> wasm32
  <subdir>/src/*.pion        non-test sources, comments stripped: word `World` -> world_free = false
  PACKAGE_META (below)       hand-curated category / summary / keywords
New packages missing from PACKAGE_META fall back to their README.md first paragraph,
category "other" and derived keywords, with a hint on stderr.
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_PATH = os.path.join(ROOT, "catalog.json")
REGISTRY = "https://github.com/AFK-surf/pion-packages.git"
SCHEMA_VERSION = 1
SUMMARY_MAX = 110

CATEGORIES = [
    ("data-formats", "Data formats & serialization / 结构化数据与序列化"),
    ("compression-archive", "Compression & archives / 压缩与归档"),
    ("crypto-auth", "Crypto, encoding & auth / 密码学、编码与鉴权"),
    ("web-net", "Web, networking & realtime / 网络、HTTP、实时通信与代理"),
    ("markup-docs", "Markup, documents & typesetting / 文档、富文本与排版"),
    ("media-graphics", "Media, graphics, fonts & GPU / 图像、音视频、字体与 GPU"),
    ("query-lang", "Query, regex, scripting & expressions / 查询、正则、脚本与表达式"),
    ("core-utils", "Core algorithms, time, versions & tooling / 基础算法、时间、版本与工程工具"),
]
CATEGORY_KEYS = [c for c, _ in CATEGORIES]
OTHER = "other"

# name -> (category, summary, keywords). Keep sorted by name.
PACKAGE_META = {
    "asn1": ("data-formats", "Strict X.690 DER, PEM, X.509 v1/v3 certificates, hostname checks and PKCS#8 key encoding",
             ["asn1", "der", "pem", "x509", "certificate", "pkcs8", "oid", "证书"]),
    "avro": ("data-formats", "Apache Avro 1.11 schemas, canonical form + Rabin fingerprint, binary/JSON codec and object container files",
             ["avro", "schema", "serialization", "binary", "fingerprint", "container", "kafka", "序列化"]),
    "base64": ("crypto-auth", "RFC 4648 Base64, Base64URL, Base32, Base32hex and hex codecs with strict decoding",
               ["base64", "base64url", "base32", "hex", "base16", "encoding", "rfc4648", "编码"]),
    "brotli": ("compression-archive", "RFC 7932 Brotli decompressor with static dictionary and decompression-bomb limits",
               ["brotli", "decompress", "rfc7932", "compression", "br", "content-encoding", "解压"]),
    "bson": ("data-formats", "BSON 1.1 codec with ObjectId, Decimal128 and MongoDB Extended JSON v2",
             ["bson", "mongodb", "objectid", "decimal128", "extended-json", "binary", "序列化"]),
    "cbor": ("data-formats", "RFC 8949 CBOR codec with deterministic/CTAP2 canonical encoding, float16 and diagnostic notation",
             ["cbor", "rfc8949", "binary", "ctap2", "webauthn", "canonical", "float16", "序列化"]),
    "cel": ("query-lang", "Google Common Expression Language: parser, macros, type checker and compiled program evaluator",
            ["cel", "expression", "policy", "type-check", "evaluator", "rules", "表达式"]),
    "cli": ("core-utils", "Declarative clap-style CLI args and subcommand parser with env fallback, help and completions",
            ["cli", "args", "argv", "flags", "subcommand", "clap", "completion", "命令行"]),
    "crdt": ("core-utils", "Yjs/YATA CRDT engine (YText, YArray, YMap) with Yjs Update v1 wire compatibility",
             ["crdt", "yjs", "yata", "collaboration", "sync", "ytext", "ymap", "协同编辑"]),
    "cron": ("core-utils", "Cron expression parser and calendar scheduler with Quartz L/W/# extensions and macros",
             ["cron", "crontab", "schedule", "quartz", "timer", "next-run", "定时任务"]),
    "crypto": ("crypto-auth", "SHA-1/2, HMAC, HKDF, PBKDF2, scrypt, AES-GCM, ChaCha20-Poly1305, Ed25519, X25519, P-256 and RSA",
               ["sha256", "sha512", "aes", "gcm", "chacha20", "ed25519", "x25519", "p256", "rsa", "pbkdf2", "scrypt",
                "hmac", "hkdf", "密码学"]),
    "csp": ("web-net", "W3C CSP Level 3 policy parsing/enforcement and WHATWG Fetch CORS checks",
            ["csp", "content-security-policy", "cors", "origin", "nonce", "preflight", "安全策略"]),
    "css": ("markup-docs", "CSS Syntax 3 tokenizer/parser, Selectors 4 specificity, Media Queries 4 and CSS Color 4",
            ["css", "stylesheet", "selector", "specificity", "media-query", "color", "oklch", "样式"]),
    "csv": ("data-formats", "Streaming RFC 4180 CSV reader/writer with flexible dialects and DoS limits",
            ["csv", "tsv", "rfc4180", "table", "delimiter", "streaming", "表格"]),
    "decimal": ("core-utils", "128-bit exact decimal arithmetic with 7 rounding modes, rust_decimal compatible serialization",
                ["decimal", "money", "fixed-point", "rounding", "arithmetic", "rust_decimal", "金额"]),
    "diff": ("core-utils", "Myers/Histogram line diff, unified patch create/parse/apply and three-way merge",
             ["diff", "patch", "myers", "histogram", "unified", "merge", "三路合并"]),
    "dns": ("web-net", "Sans-IO DNS wire codec with name compression and 18 structured record types",
            ["dns", "resolver", "rr", "rfc1035", "domain", "srv", "txt", "域名"]),
    "effect": ("core-utils", "Deterministic structured-concurrency runtime: fibers, scopes, queues, semaphores, virtual clock",
               ["effect", "fiber", "concurrency", "scheduler", "async", "runtime", "simulation", "并发"]),
    "email": ("web-net", "RFC 5322 email headers, MIME tree build/extract, DKIM sign/verify and mbox",
              ["email", "rfc5322", "mime", "dkim", "mbox", "smtp", "mail", "邮件"]),
    "encoding": ("data-formats", "WHATWG Encoding Standard codec (all 40 encodings: UTF-8/16, GB18030, Shift_JIS, Big5, EUC-KR, streaming)",
                 ["encoding", "charset", "whatwg", "textdecoder", "utf16", "gb18030", "shift-jis", "big5", "euc-kr", "字符编码"]),
    "exif": ("media-graphics", "TIFF/EXIF 2.32 metadata and orientation parser for JPEG, WebP, PNG and raw TIFF",
             ["exif", "tiff", "jpeg", "metadata", "orientation", "gps", "photo", "照片元数据"]),
    "flate": ("compression-archive", "DEFLATE, zlib and gzip compress/decompress with CRC-32/Adler-32 and zip-bomb limits",
              ["deflate", "zlib", "gzip", "inflate", "crc32", "adler32", "compression", "压缩"]),
    "fts": ("query-lang", "Multilingual code-aware full-text search with CJK bigrams and FTS5-compatible BM25 ranking",
            ["fts", "full-text", "search", "bm25", "inverted-index", "cjk", "tokenizer", "全文检索"]),
    "gif": ("media-graphics", "GIF87a/GIF89a animated image decoder with LZW, disposal, transparency and loop count",
            ["gif", "image", "animation", "lzw", "decoder", "frames", "动图"]),
    "git": ("core-utils", "Git plumbing: SHA-1/SHA-256 objects, trees, commits, packfiles, index and ref handling",
            ["git", "packfile", "oid", "commit", "tree", "blob", "plumbing", "版本控制"]),
    "glob": ("query-lang", "Glob patterns, multi-pattern GlobSet DFA and full .gitignore semantics",
             ["glob", "wildcard", "gitignore", "globset", "pattern", "path", "通配符"]),
    "glsl": ("media-graphics", "GLSL ES 1.00/3.00 lexer, validator, reflection and OpenGL 4.10 Core translator",
             ["glsl", "shader", "webgl", "opengl", "gpu", "transpile", "着色器"]),
    "graph": ("core-utils", "Directed/undirected/CSR graphs with traversal, SCC, dominators, shortest paths and flows",
              ["graph", "dijkstra", "bfs", "dfs", "scc", "toposort", "dominator", "petgraph", "图算法"]),
    "graphql": ("query-lang", "GraphQL lexer, AST parser (queries + SDL), formatter, minifier and validation rules",
                ["graphql", "query", "sdl", "schema", "parser", "minify", "查询"]),
    "hcl": ("data-formats", "HashiCorp HCL2 parser, evaluator with built-in functions and hclwrite-style formatter",
            ["hcl", "hcl2", "terraform", "config", "hashicorp", "cty", "配置"]),
    "highlight": ("markup-docs", "Incremental line-state syntax highlighter for 24 languages with HTML output",
                  ["highlight", "syntax", "code", "tokenizer", "shiki", "html", "语法高亮"]),
    "html": ("markup-docs", "WHATWG HTML5 parser, CSS selector queries, XSS sanitizer and srcset/picture selection",
             ["html", "html5", "dom", "selector", "sanitize", "xss", "parser", "网页解析"]),
    "http1": ("web-net", "Sans-IO HTTP/1.1 request/response parser and encoder with chunked coding and smuggling guards",
              ["http", "http1", "rfc9112", "request", "response", "chunked", "parser", "协议"]),
    "http2": ("web-net", "Sans-IO HTTP/2 frame codec, HPACK compression and stream/flow-control state machine",
              ["http2", "h2", "hpack", "frame", "rfc9113", "stream", "flow-control", "协议"]),
    "http_cache": ("web-net", "RFC 9111 HTTP cache policy engine, conditional requests and bounded LRU store",
                   ["http-cache", "cache-control", "etag", "vary", "lru", "rfc9111", "缓存"]),
    "hyphenation": ("markup-docs", "Knuth-Liang hyphenation engine with en-US patterns and pluggable TeX dictionaries",
                    ["hyphenation", "hyphenate", "knuth-liang", "tex", "typesetting", "line-break", "断字"]),
    "ical": ("markup-docs", "RFC 5545 iCalendar/iTIP parser and serializer with VTIMEZONE and RRULE expansion",
             ["ical", "icalendar", "ics", "rrule", "calendar", "event", "timezone", "日历"]),
    "icc": ("media-graphics", "ICC v2/v4 color profile parser, JPEG/WebP profile extraction and ICC to sRGB transforms",
            ["icc", "color-profile", "srgb", "color-management", "jpeg", "gamma", "色彩管理"]),
    "jq": ("query-lang", "jq 1.7 / gojq JSON query and transformation language engine",
           ["jq", "json", "query", "filter", "transform", "gojq", "查询"]),
    "json": ("data-formats", "Strict RFC 8259 JSON parser with lossless numbers, JSON Pointer and RFC 8785 canonical output",
             ["json", "rfc8259", "parser", "serialize", "jcs", "canonical", "json-pointer", "序列化"]),
    "json5": ("data-formats", "JSON5, JSONC and strict JSON parse/serialize with JSON Pointer and JSON Patch",
              ["json5", "jsonc", "json", "json-patch", "json-pointer", "comments", "配置"]),
    "jsonpath": ("query-lang", "RFC 9535 JSONPath with JSON Pointer, JSON Patch and JSON Merge Patch",
                 ["jsonpath", "json", "query", "json-pointer", "json-patch", "merge-patch", "查询"]),
    "jsonschema": ("query-lang", "JSON Schema 2020-12/2019-09/07/04 compiler and validator with format checks",
                   ["jsonschema", "json-schema", "validation", "schema", "draft2020-12", "format", "校验"]),
    "jwt": ("crypto-auth", "JWS/JWT/JWK with HS256/384/512, strict claim validation and alg:none rejection",
            ["jwt", "jws", "jwk", "hs256", "hmac", "token", "auth", "鉴权"]),
    "kdl": ("data-formats", "KDL v2.0 (and v1 compat) document parser and canonical/compact serializer",
            ["kdl", "config", "document", "parser", "serializer", "配置"]),
    "lua": ("query-lang", "Lua 5.4 bytecode compiler and sandboxed register VM with GC and resource limits",
            ["lua", "script", "vm", "interpreter", "sandbox", "bytecode", "脚本"]),
    "markdown": ("markup-docs", "CommonMark + GFM Markdown parser and HTML renderer with AST and plain-text preview",
                 ["markdown", "commonmark", "gfm", "html", "ast", "md", "渲染"]),
    "mermaid": ("markup-docs", "Mermaid flowchart/sequence/state/class/ER diagram parser, layout and SVG renderer",
                ["mermaid", "diagram", "flowchart", "sequence", "svg", "layout", "dagre", "图表"]),
    "mime": ("web-net", "MIME types, Content-Disposition, Accept negotiation, multipart and quoted-printable codecs",
             ["mime", "content-type", "multipart", "form-data", "accept", "quoted-printable", "文件类型"]),
    "mp4": ("media-graphics", "ISO BMFF / MP4 / fMP4 zero-copy demuxer with MSE segment parsing and codec strings",
            ["mp4", "isobmff", "fmp4", "demux", "mse", "h264", "aac", "视频"]),
    "mqtt": ("web-net", "Sans-IO MQTT 3.1.1/5.0 packet codec, streaming decoder and topic matching",
             ["mqtt", "iot", "pubsub", "broker", "topic", "packet", "消息队列"]),
    "msgpack": ("data-formats", "MessagePack codec with timestamp ext, canonical encoding and streaming decode",
                ["msgpack", "messagepack", "binary", "serialization", "timestamp", "序列化"]),
    "openapi": ("core-utils", "OpenAPI 3.0/3.1 JSON+YAML loader, $ref resolution, validation and request routing",
                ["openapi", "swagger", "api", "ref", "schema", "routing", "接口文档"]),
    "pdf": ("markup-docs", "PDF 1.4 document builder and structural validator with fonts, vector drawing and images",
            ["pdf", "document", "export", "vector", "font", "flate", "文档生成"]),
    "promql": ("query-lang", "Prometheus PromQL parser, formatter and in-memory instant/range evaluator",
               ["promql", "prometheus", "metrics", "query", "timeseries", "监控"]),
    "protobuf": ("data-formats", "Protocol Buffers wire codec, .proto schema parser and dynamic messages with JSON mapping",
                 ["protobuf", "proto", "grpc", "varint", "schema", "serialization", "序列化"]),
    "proxy": ("web-net", "Sans-IO SOCKS5 and HTTP CONNECT/forward proxy codecs with proxy URL parsing",
              ["proxy", "socks5", "connect", "http-proxy", "tunnel", "no_proxy", "代理"]),
    "qrcode": ("media-graphics", "ISO/IEC 18004 QR code encoder, Reed-Solomon decoder and SVG/RGBA/PGM/ASCII renderers",
               ["qrcode", "qr", "barcode", "reed-solomon", "svg", "encoder", "二维码"]),
    "regex": ("query-lang", "Linear-time regex engine (RE2/Rust syntax) with Unicode, captures and RegexSet",
              ["regex", "regexp", "re2", "pattern", "match", "unicode", "正则"]),
    "resp": ("web-net", "Sans-IO Redis RESP2/RESP3 codec, streaming decoder, pipelines and cluster slot hashing",
             ["resp", "redis", "resp3", "pipeline", "cluster", "protocol", "缓存"]),
    "rtp": ("web-net", "RTP/RTCP, header extensions, feedback and SRTP/SRTCP (AES-CM, AES-GCM) for WebRTC",
            ["rtp", "rtcp", "srtp", "webrtc", "media", "aes-gcm", "音视频传输"]),
    "sdp": ("web-net", "WebRTC SDP/JSEP parser and lossless serializer with BUNDLE, ICE and simulcast",
            ["sdp", "webrtc", "jsep", "ice", "simulcast", "offer-answer", "音视频"]),
    "semver": ("core-utils", "SemVer 2.0.0 parsing, precedence comparison and Cargo-style version requirements",
               ["semver", "version", "versionreq", "cargo", "compare", "版本号"]),
    "sql": ("query-lang", "SQLite/PostgreSQL SQL lexer, AST parser, canonical formatter and static analyzer",
            ["sql", "sqlite", "postgresql", "parser", "ast", "formatter", "数据库"]),
    "sse": ("web-net", "WHATWG Server-Sent Events (EventSource) streaming parser and encoder",
            ["sse", "eventsource", "server-sent-events", "streaming", "llm", "推送"]),
    "ssh": ("crypto-auth", "OpenSSH wire format, keys, fingerprints, certificates, SSHSIG and authorized_keys",
            ["ssh", "openssh", "ed25519", "certificate", "fingerprint", "authorized_keys", "sshsig", "密钥"]),
    "stun": ("web-net", "RFC 8489 STUN codec with integrity/fingerprint and Sans-IO ICE state machine",
             ["stun", "ice", "webrtc", "nat", "turn", "fingerprint", "穿透"]),
    "svg": ("markup-docs", "SVG path parsing, transforms, exact geometry, DOM, shape-to-path and SVGO-style optimizer",
            ["svg", "path", "bezier", "transform", "vector", "optimize", "矢量图"]),
    "tar": ("compression-archive", "USTAR/PAX/GNU tar streaming reader/writer with sparse files and path-traversal guards",
            ["tar", "archive", "ustar", "pax", "gnu", "sparse", "归档"]),
    "template": ("markup-docs", "Jinja2/MiniJinja-compatible template engine with inheritance, macros and auto-escaping",
                 ["template", "jinja2", "minijinja", "render", "macro", "escape", "模板"]),
    "texmath": ("markup-docs", "TeX math parser, KaTeX-compatible MathML serializer and box layout IR",
                ["tex", "latex", "math", "katex", "mathml", "formula", "数学公式"]),
    "time": ("core-utils", "Civil date/time/timestamp/duration types with RFC 3339, RFC 2822, HTTP-date and ISO 8601",
             ["time", "date", "datetime", "timestamp", "rfc3339", "duration", "iso8601", "时间"]),
    "toml": ("data-formats", "TOML v1.0.0 parser and order-preserving serializer with toml-test JSON encoding",
             ["toml", "config", "parser", "serializer", "cargo", "配置"]),
    "unicode_bidi": ("markup-docs", "Unicode 16 UAX #9 bidirectional algorithm: levels, reordering and mirroring",
                     ["bidi", "uax9", "rtl", "arabic", "hebrew", "unicode", "双向文本"]),
    "url": ("web-net", "WHATWG URL parser with IDNA/Punycode, IPv4/IPv6, percent-encoding, query params and data: URIs",
            ["url", "uri", "whatwg", "idna", "punycode", "querystring", "percent-encoding", "网址"]),
    "uuid": ("crypto-auth", "RFC 9562 UUID v1-v8 and ULID generation/parsing as zero-allocation 128-bit values",
             ["uuid", "ulid", "guid", "uuidv7", "uuidv4", "id", "唯一标识"]),
    "wasm": ("query-lang", "WebAssembly 1.0/2.0 binary decoder, streaming parser, validator and WAT disassembler",
             ["wasm", "webassembly", "binary", "validator", "wat", "module", "字节码"]),
    "webm": ("media-graphics", "EBML/Matroska/WebM zero-copy demuxer with lacing, cues and MSE byte stream support",
             ["webm", "matroska", "mkv", "ebml", "demux", "mse", "视频"]),
    "webp": ("media-graphics", "WebP static image decoder: VP8L lossless, VP8 lossy and VP8X alpha to RGBA",
             ["webp", "image", "vp8", "vp8l", "alpha", "decoder", "rgba", "图片解码"]),
    "websocket": ("web-net", "Sans-IO RFC 6455 WebSocket handshake, frame codec, fragmentation and close handling",
                  ["websocket", "ws", "rfc6455", "frame", "handshake", "realtime", "实时通信"]),
    "webvtt": ("markup-docs", "W3C WebVTT subtitle parser, cue rich-text payloads and timeline queries",
               ["webvtt", "vtt", "subtitle", "caption", "cue", "video", "字幕"]),
    "wgsl": ("media-graphics", "WGSL frontend (parse, validate, reflect) and WGSL to MSL/GLSL transpiler",
             ["wgsl", "webgpu", "shader", "msl", "metal", "glsl", "gpu", "着色器"]),
    "woff2": ("media-graphics", "WOFF 2.0 and WOFF 1.0 web font decoders to TrueType/OpenType SFNT",
              ["woff2", "woff", "font", "ttf", "otf", "sfnt", "字体"]),
    "xml": ("data-formats", "XML 1.0 + Namespaces streaming pull parser, read-only DOM and strict writer (XXE-safe)",
            ["xml", "namespace", "dom", "sax", "pull-parser", "writer", "解析"]),
    "xpath": ("query-lang", "W3C XPath 1.0 query engine with all axes and core functions over xml documents",
              ["xpath", "xml", "query", "axes", "selector", "查询"]),
    "yaml": ("data-formats", "YAML 1.2 Core Schema multi-document parser, anchors/merge keys, emitter and JSON output",
             ["yaml", "yml", "config", "parser", "emitter", "anchors", "配置"]),
    "zip": ("compression-archive", "ZIP read/write (store/deflate) with ZIP64, data descriptors and SFX offsets",
            ["zip", "archive", "zip64", "deflate", "unzip", "compression", "压缩包"]),
}

STOPWORDS = {
    "a", "an", "and", "the", "of", "for", "with", "to", "in", "on", "by", "from", "as", "is", "it", "its",
    "or", "via", "pure", "pion", "zero", "dependency", "dependencies", "world", "free", "native", "wasm32",
    "implementation", "library", "package", "based", "built", "full", "fully", "compatible", "support",
    "supports", "including", "external", "extern", "100",
}


def fail(msg):
    sys.stderr.write("gen_catalog: error: %s\n" % msg)
    sys.exit(1)


def warn(msg):
    sys.stderr.write("gen_catalog: hint: %s\n" % msg)


def parse_toml_subset(path):
    """Minimal TOML reader for the flat manifests used here.

    Returns {section: {key: value}} where top-level keys live under "".
    Basic strings are unquoted; other values (inline tables, numbers) are kept raw.
    """
    data = {"": {}}
    section = ""
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^\[\s*([A-Za-z0-9_.\-]+)\s*\]\s*(#.*)?$", line)
            if m:
                section = m.group(1)
                data.setdefault(section, {})
                continue
            m = re.match(r'^("?)([A-Za-z0-9_\-]+)\1\s*=\s*(.*)$', line)
            if not m:
                continue
            key, val = m.group(2), m.group(3).strip()
            sm = re.match(r'^"((?:\\.|[^"\\])*)"\s*(#.*)?$', val)
            if sm:
                val = sm.group(1).encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")
            data[section][key] = val
    return data


def strip_markdown(text):
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.replace("**", "").replace("__", "").replace("`", "")
    return re.sub(r"\s+", " ", text).strip()


def truncate(text, limit):
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    if " " in cut:
        cut = cut[: cut.rindex(" ")]
    return cut.rstrip(" ,;:-(") + "…"


def readme_summary(subdir):
    path = os.path.join(ROOT, subdir, "README.md")
    if not os.path.isfile(path):
        return ""
    para = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                if para:
                    break
                continue
            if line.startswith(("#", "|", "```", ">", "<!--", "- ", "* ")) and not para:
                continue
            para.append(line)
    text = strip_markdown(" ".join(para))
    m = re.match(r"^(.+?[.!?])(\s|$)", text)
    if m:
        text = m.group(1)
    return truncate(text, SUMMARY_MAX)


def derive_keywords(name, summary):
    words = [name] + [p for p in name.split("_") if p and p != name]
    for tok in re.findall(r"[A-Za-z][A-Za-z0-9.+#\-]{2,}", summary):
        t = tok.lower().strip(".-")
        if t and t not in STOPWORDS and not t.isdigit():
            words.append(t)
    out = []
    for w in words:
        if w not in out:
            out.append(w)
        if len(out) >= 8:
            break
    return out


def is_world_free(subdir):
    for path in sorted(glob.glob(os.path.join(ROOT, subdir, "src", "*.pion"))):
        if path.endswith("_test.pion"):
            continue
        with open(path, encoding="utf-8") as f:
            for raw in f:
                code = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', raw)
                code = code.split("//", 1)[0]
                if re.search(r"\bWorld\b", code):
                    return False
    return True


def build_catalog():
    index_files = sorted(glob.glob(os.path.join(ROOT, "index", "*.toml")))
    if not index_files:
        fail("no index/*.toml entries found")
    packages = []
    seen = set()
    for idx in index_files:
        rel = os.path.relpath(idx, ROOT)
        entry = parse_toml_subset(idx)[""]
        for key in ("name", "version", "git", "subdir"):
            if not entry.get(key):
                fail("%s: missing `%s`" % (rel, key))
        name = entry["name"]
        if name != os.path.splitext(os.path.basename(idx))[0]:
            fail("%s: name `%s` does not match file name" % (rel, name))
        if name in seen:
            fail("%s: duplicate package `%s`" % (rel, name))
        seen.add(name)
        if entry["git"] != REGISTRY:
            fail("%s: git `%s` is not the registry `%s`" % (rel, entry["git"], REGISTRY))
        subdir = entry["subdir"]
        manifest_path = os.path.join(ROOT, subdir, "pion.toml")
        if not os.path.isfile(manifest_path):
            fail("%s: %s/pion.toml does not exist" % (rel, subdir))
        manifest = parse_toml_subset(manifest_path)
        pkg = manifest.get("package", {})
        if pkg.get("name") != name:
            fail("%s/pion.toml: name `%s` != index `%s`" % (subdir, pkg.get("name"), name))
        if pkg.get("version") != entry["version"]:
            fail("%s/pion.toml: version `%s` != index `%s` (%s)" % (subdir, pkg.get("version"), entry["version"], rel))
        deps = sorted(manifest.get("dependencies", {}).keys())

        meta = PACKAGE_META.get(name)
        if meta is None:
            summary = readme_summary(subdir) or ("Pion package %s" % name)
            category, keywords = OTHER, derive_keywords(name, summary)
            warn("package `%s` is not in PACKAGE_META; using README summary and category `other` "
                 "-- add a curated entry to scripts/gen_catalog.py" % name)
        else:
            category, summary, keywords = meta
            if category not in CATEGORY_KEYS:
                fail("PACKAGE_META[%s]: unknown category `%s`" % (name, category))
            if not summary or len(summary) > SUMMARY_MAX:
                fail("PACKAGE_META[%s]: summary must be 1..%d chars (got %d)" % (name, SUMMARY_MAX, len(summary)))
            if not keywords or len(set(keywords)) != len(keywords):
                fail("PACKAGE_META[%s]: keywords must be non-empty and unique" % name)

        packages.append({
            "name": name,
            "version": entry["version"],
            "tag": entry.get("tag") or None,
            "subdir": subdir,
            "category": category,
            "summary": summary,
            "keywords": list(keywords),
            "deps": deps,
            "wasm32": os.path.isfile(os.path.join(ROOT, subdir, "wasm_smoke", "pion.toml")),
            "world_free": is_world_free(subdir),
        })

    names = {p["name"] for p in packages}
    for p in packages:
        missing = [d for d in p["deps"] if d not in names]
        if missing:
            fail("package `%s` depends on unpublished package(s): %s" % (p["name"], ", ".join(missing)))
    for stale in sorted(set(PACKAGE_META) - names):
        warn("PACKAGE_META has `%s` but index/%s.toml does not exist" % (stale, stale))

    packages.sort(key=lambda p: p["name"])
    return {
        "schema_version": SCHEMA_VERSION,
        "registry": REGISTRY,
        "package_count": len(packages),
        "packages": packages,
    }


def render_json(catalog):
    return (json.dumps(catalog, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def render_skill_md(catalog):
    groups = [(key, title) for key, title in CATEGORIES]
    if any(p["category"] == OTHER for p in catalog["packages"]):
        groups.append((OTHER, "Uncategorized / 未分类"))
    out = [
        "<!-- generated by `python3 scripts/gen_catalog.py --skill-md`; do not edit by hand -->",
        "%d packages · registry `%s` · install: `pionc add <name> --registry %s`"
        % (catalog["package_count"], catalog["registry"], catalog["registry"]),
        "Every package is pure Pion; ✗wasm / ✗world-free flags appear only where they are false. "
        "`← a, b` lists in-repo deps.",
    ]
    for key, title in groups:
        pkgs = [p for p in catalog["packages"] if p["category"] == key]
        if not pkgs:
            continue
        out.append("")
        out.append("### %s · `%s` (%d)" % (title, key, len(pkgs)))
        for p in pkgs:
            line = "- `%s` %s — %s" % (p["name"], p["version"], p["summary"])
            flags = []
            if not p["wasm32"]:
                flags.append("✗wasm")
            if not p["world_free"]:
                flags.append("✗world-free")
            if flags:
                line += " [%s]" % " ".join(flags)
            if p["deps"]:
                line += " ← %s" % ", ".join(p["deps"])
            out.append(line)
    return "\n".join(out) + "\n"


def main(argv):
    mode = "write"
    for arg in argv:
        if arg == "--check":
            mode = "check"
        elif arg == "--skill-md":
            mode = "skill-md"
        elif arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            fail("unknown argument `%s` (expected --check, --skill-md or nothing)" % arg)

    catalog = build_catalog()
    if mode == "skill-md":
        sys.stdout.write(render_skill_md(catalog))
        return 0

    data = render_json(catalog)
    if mode == "check":
        try:
            with open(CATALOG_PATH, "rb") as f:
                current = f.read()
        except OSError:
            fail("catalog.json is missing; run `python3 scripts/gen_catalog.py`")
        if current != data:
            fail("catalog.json is stale; run `python3 scripts/gen_catalog.py` and commit the result")
        print("catalog.json is up to date (%d packages)" % catalog["package_count"])
        return 0

    with open(CATALOG_PATH, "wb") as f:
        f.write(data)
    print("wrote catalog.json (%d packages)" % catalog["package_count"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
