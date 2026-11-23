//! Independent Rust W3C CSP Level 3 + WHATWG Fetch CORS benchmark baseline
//! powered by `servo/rust-url` (`url = 2.5`) and `percent-encoding = 2.3`,
//! compiled with `cargo build --release`.
//!
//! Uses full byte-by-byte FNV-1a 64-bit hashing over every decision field
//! (allowed, violated_directive, effective_directive, matched_source,
//! exposed_headers, origin, max_age) for strict parity with `packages/csp`.

use percent_encoding::percent_decode_str;
use std::collections::HashSet;
use std::env;
use url::{Origin as UrlOrigin, Url};

#[derive(Clone, Debug)]
enum SourceExpression {
    NoneExpr,
    SelfExpr,
    UnsafeInline,
    UnsafeEval,
    StrictDynamic,
    UnsafeHashes,
    WasmUnsafeEval,
    ReportSample,
    Nonce(String),
    Hash(String, String),
    Scheme(String),
    Host(Option<String>, String, Option<u16>, bool, String),
}

struct CspDirective {
    name: String,
    sources: Vec<SourceExpression>,
}

struct CspPolicy {
    directives: Vec<CspDirective>,
}

struct CspDecision {
    allowed: bool,
    violated_directive: String,
    effective_directive: String,
    matched_source: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CredentialsMode {
    Omit,
    Include,
}

struct CorsResponseDecision {
    allowed: bool,
    exposed_headers: Vec<String>,
    wildcard_exposed: bool,
}

struct CorsPreflightDecision {
    allowed: bool,
    max_age: i32,
}

#[inline]
fn fnv1a_byte(h: u64, b: u8) -> u64 {
    (h ^ (b as u64)).wrapping_mul(1099511628211u64)
}

#[inline]
fn fnv1a_str(mut h: u64, s: &str) -> u64 {
    for &b in s.as_bytes() {
        h = fnv1a_byte(h, b);
    }
    fnv1a_byte(h, 0xFF)
}

fn hash_decision(h: u64, d: &CspDecision) -> u64 {
    let mut h = fnv1a_byte(h, if d.allowed { 1 } else { 0 });
    h = fnv1a_str(h, &d.violated_directive);
    h = fnv1a_str(h, &d.effective_directive);
    match &d.matched_source {
        Some(s) => fnv1a_str(fnv1a_byte(h, 1), s),
        None => fnv1a_byte(h, 0),
    }
}

#[inline]
fn is_csp_ws(b: u8) -> bool {
    b == b' ' || b == b'\t' || b == 12
}

#[inline]
fn default_port(scheme: &str) -> Option<u16> {
    match scheme {
        "http" | "ws" => Some(80),
        "https" | "wss" => Some(443),
        "ftp" => Some(21),
        _ => None,
    }
}

fn is_valid_scheme(s: &str) -> bool {
    let bytes = s.as_bytes();
    !bytes.is_empty()
        && bytes[0].is_ascii_alphabetic()
        && bytes[1..]
            .iter()
            .all(|&b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
}

fn is_valid_host_part(host: &str) -> bool {
    if host.is_empty() {
        return false;
    }
    if host == "*" {
        return true;
    }
    if host.starts_with('[') && host.ends_with(']') && host.len() >= 3 {
        return host[1..host.len() - 1]
            .bytes()
            .all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'.');
    }
    let body = if let Some(rest) = host.strip_prefix("*.") {
        if rest.is_empty() {
            return false;
        }
        rest
    } else {
        host
    };
    body.bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.')
}

fn format_source_expression(expr: &SourceExpression) -> String {
    match expr {
        SourceExpression::NoneExpr => "'none'".to_string(),
        SourceExpression::SelfExpr => "'self'".to_string(),
        SourceExpression::UnsafeInline => "'unsafe-inline'".to_string(),
        SourceExpression::UnsafeEval => "'unsafe-eval'".to_string(),
        SourceExpression::StrictDynamic => "'strict-dynamic'".to_string(),
        SourceExpression::UnsafeHashes => "'unsafe-hashes'".to_string(),
        SourceExpression::WasmUnsafeEval => "'wasm-unsafe-eval'".to_string(),
        SourceExpression::ReportSample => "'report-sample'".to_string(),
        SourceExpression::Nonce(v) => format!("'nonce-{}'", v),
        SourceExpression::Hash(alg, v) => format!("'{}-{}'", alg, v),
        SourceExpression::Scheme(s) => format!("{}:", s),
        SourceExpression::Host(opt_scheme, host, opt_port, port_wild, path) => {
            let mut out = String::new();
            if let Some(sch) = opt_scheme {
                out.push_str(sch);
                out.push_str("://");
            }
            out.push_str(host);
            if *port_wild {
                out.push_str(":*");
            } else if let Some(p) = opt_port {
                out.push(':');
                out.push_str(&p.to_string());
            }
            if !path.is_empty() {
                out.push_str(path);
            }
            out
        }
    }
}

fn parse_source_expression(tok: &str) -> Option<SourceExpression> {
    if tok.is_empty() || !tok.is_ascii() {
        return None;
    }
    let n = tok.len();
    if n >= 2 && tok.starts_with('\'') && tok.ends_with('\'') {
        let lower = tok.to_ascii_lowercase();
        return match lower.as_str() {
            "'none'" => Some(SourceExpression::NoneExpr),
            "'self'" => Some(SourceExpression::SelfExpr),
            "'unsafe-inline'" => Some(SourceExpression::UnsafeInline),
            "'unsafe-eval'" => Some(SourceExpression::UnsafeEval),
            "'strict-dynamic'" => Some(SourceExpression::StrictDynamic),
            "'unsafe-hashes'" => Some(SourceExpression::UnsafeHashes),
            "'wasm-unsafe-eval'" => Some(SourceExpression::WasmUnsafeEval),
            "'report-sample'" => Some(SourceExpression::ReportSample),
            _ if lower.starts_with("'nonce-") && n > 8 => {
                Some(SourceExpression::Nonce(tok[7..n - 1].to_string()))
            }
            _ if lower.starts_with("'sha256-") && n > 9 => Some(SourceExpression::Hash(
                "sha256".to_string(),
                tok[8..n - 1].to_string(),
            )),
            _ if lower.starts_with("'sha384-") && n > 9 => Some(SourceExpression::Hash(
                "sha384".to_string(),
                tok[8..n - 1].to_string(),
            )),
            _ if lower.starts_with("'sha512-") && n > 9 => Some(SourceExpression::Hash(
                "sha512".to_string(),
                tok[8..n - 1].to_string(),
            )),
            _ => None,
        };
    }
    if tok.starts_with('\'') || tok.contains(',') {
        return None;
    }
    if tok == "*" {
        return Some(SourceExpression::Host(
            None,
            "*".to_string(),
            None,
            false,
            String::new(),
        ));
    }
    if tok.ends_with(':') && !tok.contains('/') {
        let sch = &tok[..n - 1];
        if is_valid_scheme(sch) {
            return Some(SourceExpression::Scheme(sch.to_ascii_lowercase()));
        }
        return None;
    }

    let (opt_scheme, rest) = match tok.find("://") {
        Some(sep) => {
            let sch = &tok[..sep];
            if !is_valid_scheme(sch) {
                return None;
            }
            (Some(sch.to_ascii_lowercase()), &tok[sep + 3..])
        }
        None => (None, tok),
    };
    if rest.is_empty() {
        return None;
    }
    let (hostport, path) = match rest.find('/') {
        Some(slash) => {
            let mut p = &rest[slash..];
            if let Some(q) = p.find('?') {
                p = &p[..q];
            }
            if let Some(h) = p.find('#') {
                p = &p[..h];
            }
            (&rest[..slash], p.to_string())
        }
        None => (rest, String::new()),
    };
    if hostport.is_empty() {
        return None;
    }
    let (host, opt_port, port_wild) = if hostport.starts_with('[') {
        let rb = hostport.find(']')?;
        let h = hostport[..=rb].to_ascii_lowercase();
        let tail = &hostport[rb + 1..];
        if tail.is_empty() {
            (h, None, false)
        } else if let Some(pstr) = tail.strip_prefix(':') {
            if pstr == "*" {
                (h, None, true)
            } else {
                (h, Some(pstr.parse::<u16>().ok()?), false)
            }
        } else {
            return None;
        }
    } else if let Some(colon) = hostport.find(':') {
        let h = hostport[..colon].to_ascii_lowercase();
        let pstr = &hostport[colon + 1..];
        if pstr == "*" {
            (h, None, true)
        } else {
            (h, Some(pstr.parse::<u16>().ok()?), false)
        }
    } else {
        (hostport.to_ascii_lowercase(), None, false)
    };
    if !is_valid_host_part(&host) {
        return None;
    }
    Some(SourceExpression::Host(
        opt_scheme, host, opt_port, port_wild, path,
    ))
}

fn is_source_list_directive(name: &str) -> bool {
    !matches!(
        name,
        "upgrade-insecure-requests"
            | "block-all-mixed-content"
            | "sandbox"
            | "report-uri"
            | "report-to"
            | "require-trusted-types-for"
            | "trusted-types"
    )
}

fn parse_csp(header: &str) -> Result<CspPolicy, &'static str> {
    if header.len() > 65536 {
        return Err("header too large");
    }
    for &b in header.as_bytes() {
        if b == 0 || b == 10 || b == 13 || b == 127 || (b < 32 && b != 9 && b != 12) {
            return Err("invalid control byte");
        }
    }
    let first_policy = header.split(',').next().unwrap_or("");
    let mut directives = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for raw in first_policy.split(';') {
        let trimmed = raw.trim_matches(|c: char| is_csp_ws(c as u8));
        if trimmed.is_empty() {
            continue;
        }
        let mut iter = trimmed
            .split(|c: char| is_csp_ws(c as u8))
            .filter(|s| !s.is_empty());
        let name_raw = match iter.next() {
            Some(n) if n.is_ascii() => n,
            _ => continue,
        };
        let name = name_raw.to_ascii_lowercase();
        if !seen.insert(name.clone()) {
            continue;
        }
        let parse_sources = is_source_list_directive(&name);
        let mut sources = Vec::new();
        for tok in iter {
            if !tok.is_ascii() {
                continue;
            }
            if parse_sources {
                if let Some(expr) = parse_source_expression(tok) {
                    sources.push(expr);
                }
            }
        }
        directives.push(CspDirective { name, sources });
    }
    Ok(CspPolicy { directives })
}

fn scheme_matches(expr_scheme: &str, target_scheme: &str) -> bool {
    expr_scheme == target_scheme
        || (expr_scheme == "http" && target_scheme == "https")
        || (expr_scheme == "ws" && matches!(target_scheme, "wss" | "http" | "https"))
        || (expr_scheme == "wss" && target_scheme == "https")
}

fn host_matches(pat: &str, target_host: &str) -> bool {
    if pat == "*" {
        return !target_host.is_empty();
    }
    if let Some(suffix) = pat.strip_prefix('*') {
        if suffix.starts_with('.') {
            return target_host.len() > suffix.len() && target_host.ends_with(suffix);
        }
    }
    pat == target_host
}

fn path_has_encoded_slash(path: &str) -> bool {
    let bytes = path.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] == b'\\' {
            return true;
        }
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let c1 = bytes[i + 1];
            let c2 = bytes[i + 2];
            if (c1 == b'2' && (c2 == b'f' || c2 == b'F'))
                || (c1 == b'5' && (c2 == b'c' || c2 == b'C'))
            {
                return true;
            }
        }
    }
    false
}

fn path_matches(expr_path: &str, target_path: &str) -> bool {
    if expr_path.is_empty() {
        return true;
    }
    if expr_path == "/" && target_path.is_empty() {
        return true;
    }
    if path_has_encoded_slash(target_path) {
        return false;
    }
    let exact = !expr_path.ends_with('/');
    let a: Vec<&str> = expr_path.split('/').collect();
    let b: Vec<&str> = target_path.split('/').collect();
    if a.len() > b.len() || (exact && a.len() != b.len()) {
        return false;
    }
    let check_len = if exact { a.len() } else { a.len() - 1 };
    for i in 0..check_len {
        let da = percent_decode_str(a[i]).decode_utf8_lossy();
        let db = percent_decode_str(b[i]).decode_utf8_lossy();
        if da != db {
            return false;
        }
    }
    true
}

fn expr_matches_url(
    expr: &SourceExpression,
    page: Option<&(String, String, u16)>,
    target: &Url,
) -> bool {
    let ts = target.scheme();
    let th = target.host_str().unwrap_or("");
    match expr {
        SourceExpression::NoneExpr => false,
        SourceExpression::SelfExpr => {
            let (ps, ph, pp) = match page {
                Some(p) => p,
                None => return false,
            };
            if th.is_empty() || ph != th {
                return false;
            }
            let tp = target.port_or_known_default();
            if ps == ts && tp == Some(*pp) {
                return true;
            }
            let port_ok = tp == Some(*pp)
                || (default_port(ps) == Some(*pp)
                    && default_port(ts).is_some()
                    && tp == default_port(ts));
            if !port_ok {
                return false;
            }
            ts == "https" || ts == "wss" || (ps == "http" && (ts == "http" || ts == "ws"))
        }
        SourceExpression::Scheme(s) => scheme_matches(s, ts),
        SourceExpression::Host(opt_scheme, host_pat, opt_port, port_wild, path_pat) => {
            if opt_scheme.is_none()
                && opt_port.is_none()
                && !*port_wild
                && host_pat == "*"
                && path_pat.is_empty()
            {
                if matches!(ts, "data" | "blob" | "filesystem" | "javascript" | "about") {
                    return false;
                }
                return matches!(ts, "http" | "https" | "ws" | "wss")
                    || page.map(|(ps, _, _)| ps == ts).unwrap_or(false);
            }
            if th.is_empty() {
                return false;
            }
            match opt_scheme {
                Some(es) => {
                    if !scheme_matches(es, ts) {
                        return false;
                    }
                }
                None => match page {
                    Some((ps, _, _)) => {
                        if !scheme_matches(ps, ts) {
                            return false;
                        }
                    }
                    None => return false,
                },
            }
            if !host_matches(host_pat, th) {
                return false;
            }
            if !*port_wild {
                match opt_port {
                    Some(ep) => {
                        let eff = target.port_or_known_default();
                        if eff != Some(*ep) {
                            let up = *ep == 80 && (ts == "https" || ts == "wss") && eff == Some(443);
                            if !up {
                                return false;
                            }
                        }
                    }
                    None => {
                        if target.port().is_some() {
                            return false;
                        }
                    }
                }
            }
            path_matches(path_pat, target.path())
        }
        _ => false,
    }
}

fn find_dir<'a>(policy: &'a CspPolicy, name: &str) -> Option<&'a CspDirective> {
    policy.directives.iter().find(|d| d.name == name)
}

fn is_non_fetch_directive(d: &str) -> bool {
    matches!(
        d,
        "base-uri"
            | "form-action"
            | "frame-ancestors"
            | "sandbox"
            | "navigate-to"
            | "report-uri"
            | "report-to"
            | "upgrade-insecure-requests"
            | "block-all-mixed-content"
            | "require-trusted-types-for"
            | "trusted-types"
            | "plugin-types"
            | "referrer"
            | "disown-opener"
    )
}

fn find_effective_directive<'a>(policy: &'a CspPolicy, directive: &str) -> Option<&'a CspDirective> {
    if let Some(d) = find_dir(policy, directive) {
        return Some(d);
    }
    match directive {
        "script-src-elem" | "script-src-attr" => {
            find_dir(policy, "script-src").or_else(|| find_dir(policy, "default-src"))
        }
        "style-src-elem" | "style-src-attr" => {
            find_dir(policy, "style-src").or_else(|| find_dir(policy, "default-src"))
        }
        "worker-src" => find_dir(policy, "child-src")
            .or_else(|| find_dir(policy, "script-src"))
            .or_else(|| find_dir(policy, "default-src")),
        "fenced-frame-src" => find_dir(policy, "frame-src")
            .or_else(|| find_dir(policy, "child-src"))
            .or_else(|| find_dir(policy, "default-src")),
        "frame-src" => find_dir(policy, "child-src").or_else(|| find_dir(policy, "default-src")),
        d if is_non_fetch_directive(d) => None,
        _ => find_dir(policy, "default-src"),
    }
}

fn parse_page_origin(page: &str) -> Option<(String, String, u16)> {
    let u = Url::parse(page).ok()?;
    match u.origin() {
        UrlOrigin::Tuple(s, h, p) => Some((s, h.to_string(), p)),
        UrlOrigin::Opaque(_) => None,
    }
}

fn check_source(
    policy: &CspPolicy,
    directive: &str,
    page_origin: &str,
    target_url: &str,
    nonce: &str,
    hashes: &[(&str, &str)],
    is_parser_inserted: bool,
) -> CspDecision {
    let eff = directive.to_ascii_lowercase();
    let dir = match find_effective_directive(policy, &eff) {
        Some(d) => d,
        None => {
            return CspDecision {
                allowed: true,
                violated_directive: String::new(),
                effective_directive: eff,
                matched_source: None,
            }
        }
    };
    if dir.sources.is_empty() {
        return CspDecision {
            allowed: false,
            violated_directive: dir.name.clone(),
            effective_directive: eff,
            matched_source: None,
        };
    }
    if matches!(eff.as_str(), "script-src" | "script-src-elem" | "worker-src") {
        if !nonce.is_empty() {
            for s in &dir.sources {
                if let SourceExpression::Nonce(v) = s {
                    if v == nonce {
                        return CspDecision {
                            allowed: true,
                            violated_directive: String::new(),
                            effective_directive: eff,
                            matched_source: Some(format!("'nonce-{}'", v)),
                        };
                    }
                }
            }
        }
        if !hashes.is_empty() {
            for s in &dir.sources {
                if let SourceExpression::Hash(alg, dig) = s {
                    for &(halg, hval) in hashes {
                        if halg.eq_ignore_ascii_case(alg) && hval == dig {
                            return CspDecision {
                                allowed: true,
                                violated_directive: String::new(),
                                effective_directive: eff,
                                matched_source: Some(format!("'{}-{}'", alg, dig)),
                            };
                        }
                    }
                }
            }
        }
        if dir
            .sources
            .iter()
            .any(|s| matches!(s, SourceExpression::StrictDynamic))
        {
            if !is_parser_inserted {
                return CspDecision {
                    allowed: true,
                    violated_directive: String::new(),
                    effective_directive: eff,
                    matched_source: Some("'strict-dynamic'".to_string()),
                };
            }
            return CspDecision {
                allowed: false,
                violated_directive: dir.name.clone(),
                effective_directive: eff,
                matched_source: None,
            };
        }
    }

    let target = match Url::parse(target_url) {
        Ok(u) => u,
        Err(_) => {
            return CspDecision {
                allowed: false,
                violated_directive: dir.name.clone(),
                effective_directive: eff,
                matched_source: None,
            }
        }
    };
    let page = parse_page_origin(page_origin);
    for expr in &dir.sources {
        if expr_matches_url(expr, page.as_ref(), &target) {
            return CspDecision {
                allowed: true,
                violated_directive: String::new(),
                effective_directive: eff,
                matched_source: Some(format_source_expression(expr)),
            };
        }
    }
    CspDecision {
        allowed: false,
        violated_directive: dir.name.clone(),
        effective_directive: eff,
        matched_source: None,
    }
}

fn check_inline_script(
    policy: &CspPolicy,
    nonce: &str,
    hashes: &[(&str, &str)],
    is_attribute: bool,
) -> CspDecision {
    let eff = if is_attribute {
        "script-src-attr"
    } else {
        "script-src-elem"
    }
    .to_string();
    let dir = match find_effective_directive(policy, &eff) {
        Some(d) => d,
        None => {
            return CspDecision {
                allowed: true,
                violated_directive: String::new(),
                effective_directive: eff,
                matched_source: None,
            }
        }
    };
    if !is_attribute && !nonce.is_empty() {
        for s in &dir.sources {
            if let SourceExpression::Nonce(v) = s {
                if v == nonce {
                    return CspDecision {
                        allowed: true,
                        violated_directive: String::new(),
                        effective_directive: eff,
                        matched_source: Some(format!("'nonce-{}'", v)),
                    };
                }
            }
        }
    }
    let has_unsafe_hashes = dir
        .sources
        .iter()
        .any(|s| matches!(s, SourceExpression::UnsafeHashes));
    if (!is_attribute || has_unsafe_hashes) && !hashes.is_empty() {
        for s in &dir.sources {
            if let SourceExpression::Hash(alg, dig) = s {
                for &(halg, hval) in hashes {
                    if halg.eq_ignore_ascii_case(alg) && hval == dig {
                        return CspDecision {
                            allowed: true,
                            violated_directive: String::new(),
                            effective_directive: eff,
                            matched_source: Some(format!("'{}-{}'", alg, dig)),
                        };
                    }
                }
            }
        }
    }
    let has_nhs = dir.sources.iter().any(|s| {
        matches!(
            s,
            SourceExpression::Nonce(_)
                | SourceExpression::Hash(_, _)
                | SourceExpression::StrictDynamic
        )
    });
    if !has_nhs
        && dir
            .sources
            .iter()
            .any(|s| matches!(s, SourceExpression::UnsafeInline))
    {
        return CspDecision {
            allowed: true,
            violated_directive: String::new(),
            effective_directive: eff,
            matched_source: Some("'unsafe-inline'".to_string()),
        };
    }
    CspDecision {
        allowed: false,
        violated_directive: dir.name.clone(),
        effective_directive: eff,
        matched_source: None,
    }
}

fn check_eval(policy: &CspPolicy) -> CspDecision {
    let eff = "script-src".to_string();
    let dir = match find_effective_directive(policy, &eff) {
        Some(d) => d,
        None => {
            return CspDecision {
                allowed: true,
                violated_directive: String::new(),
                effective_directive: eff,
                matched_source: None,
            }
        }
    };
    if dir
        .sources
        .iter()
        .any(|s| matches!(s, SourceExpression::UnsafeEval))
    {
        return CspDecision {
            allowed: true,
            violated_directive: String::new(),
            effective_directive: eff,
            matched_source: Some("'unsafe-eval'".to_string()),
        };
    }
    CspDecision {
        allowed: false,
        violated_directive: dir.name.clone(),
        effective_directive: eff,
        matched_source: None,
    }
}

fn check_wasm_eval(policy: &CspPolicy) -> CspDecision {
    let eff = "script-src".to_string();
    let dir = match find_effective_directive(policy, &eff) {
        Some(d) => d,
        None => {
            return CspDecision {
                allowed: true,
                violated_directive: String::new(),
                effective_directive: eff,
                matched_source: None,
            }
        }
    };
    for s in &dir.sources {
        match s {
            SourceExpression::WasmUnsafeEval => {
                return CspDecision {
                    allowed: true,
                    violated_directive: String::new(),
                    effective_directive: eff,
                    matched_source: Some("'wasm-unsafe-eval'".to_string()),
                };
            }
            SourceExpression::UnsafeEval => {
                return CspDecision {
                    allowed: true,
                    violated_directive: String::new(),
                    effective_directive: eff,
                    matched_source: Some("'unsafe-eval'".to_string()),
                };
            }
            _ => {}
        }
    }
    CspDecision {
        allowed: false,
        violated_directive: dir.name.clone(),
        effective_directive: eff,
        matched_source: None,
    }
}

// ============================================================================
// WHATWG Fetch CORS (using `url::Url::origin`)
// ============================================================================

fn is_cors_safelisted_method(method: &str) -> bool {
    matches!(method, "GET" | "HEAD" | "POST")
}

fn has_unsafe_header_byte(s: &str) -> bool {
    s.bytes().any(|b| {
        (b < 0x20 && b != 0x09)
            || b == 0x7F
            || matches!(
                b,
                b'"' | b'(' | b')' | b':' | b'<' | b'>' | b'?' | b'@' | b'[' | b'\\' | b']' | b'{' | b'}'
            )
    })
}

fn is_cors_safelisted_request_header(name: &str, value: &str) -> bool {
    if value.len() > 128 {
        return false;
    }
    let ln = name.trim().to_ascii_lowercase();
    match ln.as_str() {
        "accept" => !has_unsafe_header_byte(value),
        "accept-language" | "content-language" => value.bytes().all(|b| {
            b.is_ascii_alphanumeric()
                || matches!(b, b' ' | b'*' | b',' | b'-' | b'.' | b';' | b'=')
        }),
        "content-type" => {
            if has_unsafe_header_byte(value) {
                return false;
            }
            let essence = value
                .split(';')
                .next()
                .unwrap_or("")
                .trim()
                .to_ascii_lowercase();
            matches!(
                essence.as_str(),
                "application/x-www-form-urlencoded" | "multipart/form-data" | "text/plain"
            )
        }
        _ => false,
    }
}

fn parse_origin(raw: &str) -> UrlOrigin {
    match Url::parse(raw) {
        Ok(u) => u.origin(),
        Err(_) => UrlOrigin::new_opaque(),
    }
}

fn origin_equals(a: &UrlOrigin, b: &UrlOrigin) -> bool {
    match (a, b) {
        (UrlOrigin::Tuple(sa, ha, pa), UrlOrigin::Tuple(sb, hb, pb)) => {
            sa == sb && ha == hb && pa == pb
        }
        _ => false,
    }
}

fn validate_origin_and_creds(
    request_origin: &str,
    mode: CredentialsMode,
    allow_origin: Option<&str>,
    allow_credentials: Option<&str>,
) -> bool {
    let req = request_origin.trim();
    if req.is_empty() {
        return false;
    }
    let acao = match allow_origin {
        Some(v) => v.trim(),
        None => return false,
    };
    if acao.is_empty() || acao.contains(',') {
        return false;
    }
    if mode == CredentialsMode::Include {
        if acao == "*" || acao != req {
            return false;
        }
        matches!(allow_credentials.map(|v| v.trim()), Some("true"))
    } else {
        acao == "*" || acao == req
    }
}

fn check_cors_response(
    request_origin: &str,
    mode: CredentialsMode,
    allow_origin: Option<&str>,
    allow_credentials: Option<&str>,
    expose_headers: Option<&str>,
) -> CorsResponseDecision {
    if !validate_origin_and_creds(request_origin, mode, allow_origin, allow_credentials) {
        return CorsResponseDecision {
            allowed: false,
            exposed_headers: Vec::new(),
            wildcard_exposed: false,
        };
    }
    let include = mode == CredentialsMode::Include;
    let mut exposed = Vec::new();
    let mut wildcard_exposed = false;
    if let Some(raw) = expose_headers {
        for part in raw.split(',') {
            let item = part.trim().to_ascii_lowercase();
            if item.is_empty() {
                continue;
            }
            if item == "*" {
                if !include {
                    wildcard_exposed = true;
                }
            } else {
                exposed.push(item);
            }
        }
    }
    CorsResponseDecision {
        allowed: true,
        exposed_headers: exposed,
        wildcard_exposed,
    }
}

fn check_cors_preflight(
    request_origin: &str,
    mode: CredentialsMode,
    request_method: &str,
    request_headers: &[&str],
    allow_origin: Option<&str>,
    allow_credentials: Option<&str>,
    allow_methods: Option<&str>,
    allow_headers: Option<&str>,
    max_age: Option<&str>,
) -> CorsPreflightDecision {
    if !validate_origin_and_creds(request_origin, mode, allow_origin, allow_credentials) {
        return CorsPreflightDecision {
            allowed: false,
            max_age: 0,
        };
    }
    let include = mode == CredentialsMode::Include;
    let mut method_ok = is_cors_safelisted_method(request_method);
    if !method_ok {
        if let Some(raw) = allow_methods {
            for m in raw.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()) {
                if m == request_method || (m == "*" && !include) {
                    method_ok = true;
                    break;
                }
            }
        }
    }
    if !method_ok {
        return CorsPreflightDecision {
            allowed: false,
            max_age: 0,
        };
    }
    if !request_headers.is_empty() {
        let allowed_hdrs: Vec<String> = allow_headers
            .map(|raw| {
                raw.split(',')
                    .map(|s| s.trim().to_ascii_lowercase())
                    .filter(|s| !s.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let has_wildcard = !include && allowed_hdrs.iter().any(|h| h == "*");
        for &rh in request_headers {
            let lrh = rh.trim().to_ascii_lowercase();
            if lrh.is_empty() {
                continue;
            }
            let ok = allowed_hdrs.iter().any(|h| h == &lrh)
                || (has_wildcard && lrh != "authorization");
            if !ok {
                return CorsPreflightDecision {
                    allowed: false,
                    max_age: 0,
                };
            }
        }
    }
    let parsed_max_age = max_age
        .and_then(|s| s.trim().parse::<i32>().ok())
        .filter(|&v| v >= 0)
        .map(|v| v.min(86400))
        .unwrap_or(0);
    CorsPreflightDecision {
        allowed: true,
        max_age: parsed_max_age,
    }
}

fn bench_csp(rounds: i32) {
    let h_twitter = "default-src 'none'; connect-src 'self' https://api.x.com https://api.twitter.com wss://*.x.com https://upload.twitter.com/1.1/; font-src 'self' https://abs.twimg.com data:; frame-src https://twitter.com https://mobile.twitter.com https://accounts.google.com; img-src https: blob: data: *.twimg.com; media-src https://video.twimg.com blob:; object-src 'none'; script-src 'self' 'nonce-TwItTeR99' 'strict-dynamic' https://abs.twimg.com/responsive-web/ 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://abs.twimg.com; worker-src 'self' blob:; base-uri 'self'; form-action 'self' https://x.com; frame-ancestors 'none'; report-uri https://x.com/i/csp_report";
    let h_youtube = "default-src 'none'; script-src 'nonce-YtNoNcE42' 'strict-dynamic' 'unsafe-eval' https://www.youtube.com/s/ https://www.gstatic.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' https://i.ytimg.com https://*.ggpht.com data: blob:; media-src 'self' https://*.googlevideo.com blob:; connect-src 'self' https://*.googlevideo.com https://www.youtube.com https://play.google.com; font-src https://fonts.gstatic.com; frame-src https://accounts.google.com https://www.youtube.com; worker-src 'self' blob:; base-uri 'self'; object-src 'none'; upgrade-insecure-requests; report-to yt-csp";
    let h_github = "default-src 'none'; base-uri 'self'; child-src github.com/assets-cdn/worker/ gist.github.com/assets-cdn/worker/; connect-src 'self' https://uploads.github.com https://api.github.com wss://alive.github.com https://collector.github.com; font-src github.githubassets.com; form-action 'self' github.com gist.github.com; frame-ancestors 'none'; frame-src render.githubusercontent.com viewscreen.githubusercontent.com; img-src 'self' data: blob: https://avatars.githubusercontent.com *.githubusercontent.com github.githubassets.com; manifest-src 'self'; media-src github.com user-images.githubusercontent.com; script-src github.githubassets.com; style-src 'unsafe-inline' github.githubassets.com; worker-src github.com/assets-cdn/worker/ gist.github.com/assets-cdn/worker/";
    let h_meet = "default-src 'self'; script-src 'nonce-MeEt2026' 'strict-dynamic' 'wasm-unsafe-eval' https://meet.google.com https://www.gstatic.com; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' https://lh3.googleusercontent.com https://*.gstatic.com data: blob:; media-src 'self' blob: mediastream:; connect-src 'self' https://meet.google.com wss://*.google.com https://*.googleapis.com; font-src https://fonts.gstatic.com; frame-src https://docs.google.com https://accounts.google.com; worker-src 'self' blob:; object-src 'none'; base-uri 'self'; upgrade-insecure-requests";
    let h_figma = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' https://static.figma.com/webpack/ 'sha256-FigMaHash01='; style-src 'self' 'unsafe-inline' https://static.figma.com; img-src 'self' data: blob: https://*.figma.com https://s3-alpha.figma.com; connect-src 'self' wss://www.figma.com https://api.figma.com https://static.figma.com; font-src 'self' https://static.figma.com data:; worker-src 'self' blob:; frame-ancestors 'self'; base-uri 'self'; object-src 'none'; upgrade-insecure-requests";

    let headers = [h_twitter, h_youtube, h_github, h_meet, h_figma];
    let origins = [
        "https://x.com",
        "https://www.youtube.com",
        "https://github.com",
        "https://meet.google.com",
        "https://www.figma.com",
    ];

    let mut digest: u64 = 14695981039346656037u64;
    let mut allowed_count: i32 = 0;
    let mut blocked_count: i32 = 0;
    let mut total_directives: usize = 0;
    let mut total_sources: usize = 0;

    for _ in 0..rounds {
        for s in 0..5 {
            let p = parse_csp(headers[s]).expect("valid csp");
            total_directives += p.directives.len();
            for d in &p.directives {
                total_sources += d.sources.len();
            }
            let orig = origins[s];
            let ds = [
                check_source(&p, "script-src-elem", orig, "https://abs.twimg.com/responsive-web/app.js", "TwItTeR99", &[], true),
                check_source(&p, "script-src", orig, "https://static.figma.com/webp%61ck/main.js", "", &[("sha256", "FigMaHash01=")], true),
                check_source(&p, "script-src", orig, "https://evil.example\\@abs.twimg.com/xss.js", "", &[], true),
                check_source(&p, "img-src", orig, "https://avatars.githubusercontent.com/u/42", "", &[], true),
                check_source(&p, "img-src", orig, "data:image/png;base64,AA==", "", &[], true),
                check_source(&p, "connect-src", orig, "wss://www.figma.com/ws", "", &[], true),
                check_source(&p, "worker-src", orig, "https://github.com/assets-cdn/worker/.\t./escape.js", "", &[], true),
                check_inline_script(&p, "YtNoNcE42", &[], false),
                check_eval(&p),
                check_wasm_eval(&p),
            ];
            for d in &ds {
                if d.allowed {
                    allowed_count += 1;
                } else {
                    blocked_count += 1;
                }
                digest = hash_decision(digest, d);
            }
        }
    }

    println!("mode=csp");
    println!("rounds={}", rounds);
    println!("directives={}", total_directives);
    println!("sources={}", total_sources);
    println!("allowed={}", allowed_count);
    println!("blocked={}", blocked_count);
    println!("fnv1a64={:016x}", digest);
}

fn bench_cors(rounds: i32) {
    let mut digest: u64 = 14695981039346656037u64;
    let mut allowed_count: i32 = 0;
    let mut blocked_count: i32 = 0;
    let mut max_age_sum: i64 = 0;

    for _ in 0..rounds {
        let o1 = parse_origin("https://App.Example.COM:443/v1/feed");
        let o2 = parse_origin("blob:https://app.example.com/550e8400");
        let o3 = parse_origin("https://evil.com\\@app.example.com/");
        let eq12 = origin_equals(&o1, &o2);
        let eq13 = origin_equals(&o1, &o3);
        digest = fnv1a_str(digest, &o1.ascii_serialization());
        digest = fnv1a_str(digest, &o2.ascii_serialization());
        digest = fnv1a_str(digest, &o3.ascii_serialization());
        if eq12 && !eq13 {
            allowed_count += 1;
            digest = fnv1a_byte(digest, 1);
        } else {
            blocked_count += 1;
            digest = fnv1a_byte(digest, 0);
        }

        let safe1 = is_cors_safelisted_method("POST")
            && is_cors_safelisted_request_header("Content-Type", "text/plain; charset=utf-8");
        let safe2 = is_cors_safelisted_request_header("Content-Type", "application/json");
        if safe1 && !safe2 {
            allowed_count += 1;
            digest = fnv1a_byte(digest, 1);
        } else {
            blocked_count += 1;
            digest = fnv1a_byte(digest, 0);
        }

        let r1 = check_cors_response(
            "https://x.com",
            CredentialsMode::Include,
            Some("https://x.com"),
            Some("true"),
            Some("X-Rate-Limit-Remaining, X-Request-Id, *"),
        );
        if r1.allowed && !r1.wildcard_exposed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        digest = fnv1a_byte(digest, if r1.allowed { 1 } else { 0 });
        digest = fnv1a_byte(digest, if r1.wildcard_exposed { 1 } else { 0 });
        for h in &r1.exposed_headers {
            digest = fnv1a_str(digest, h);
        }

        let r2 = check_cors_response(
            "https://x.com",
            CredentialsMode::Include,
            Some("*"),
            Some("true"),
            None,
        );
        if r2.allowed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        digest = fnv1a_byte(digest, if r2.allowed { 1 } else { 0 });

        let r3 = check_cors_response(
            "https://github.com",
            CredentialsMode::Omit,
            Some("*"),
            None,
            Some("ETag, *"),
        );
        if r3.allowed && r3.wildcard_exposed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        digest = fnv1a_byte(digest, if r3.allowed { 1 } else { 0 });
        digest = fnv1a_byte(digest, if r3.wildcard_exposed { 1 } else { 0 });
        for h in &r3.exposed_headers {
            digest = fnv1a_str(digest, h);
        }

        let r4 = check_cors_response(
            "https://github.com",
            CredentialsMode::Omit,
            Some("https://github.com, https://evil.com"),
            None,
            None,
        );
        if r4.allowed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        digest = fnv1a_byte(digest, if r4.allowed { 1 } else { 0 });

        let pf1 = check_cors_preflight(
            "https://www.figma.com",
            CredentialsMode::Omit,
            "PUT",
            &["X-Figma-Token", "Authorization"],
            Some("*"),
            None,
            Some("GET, POST, PUT, DELETE"),
            Some("*"),
            Some("600"),
        );
        if pf1.allowed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        max_age_sum += pf1.max_age as i64;
        digest = fnv1a_byte(digest, if pf1.allowed { 1 } else { 0 });
        digest = fnv1a_str(digest, &pf1.max_age.to_string());

        let pf2 = check_cors_preflight(
            "https://www.figma.com",
            CredentialsMode::Omit,
            "PUT",
            &["X-Figma-Token", "Authorization"],
            Some("*"),
            None,
            Some("GET, POST, PUT, DELETE"),
            Some("*, Authorization"),
            Some("999999999"),
        );
        if pf2.allowed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        max_age_sum += pf2.max_age as i64;
        digest = fnv1a_byte(digest, if pf2.allowed { 1 } else { 0 });
        digest = fnv1a_str(digest, &pf2.max_age.to_string());

        let pf3 = check_cors_preflight(
            "https://meet.google.com",
            CredentialsMode::Include,
            "PATCH",
            &["Content-Type", "X-Goog-AuthUser"],
            Some("https://meet.google.com"),
            Some("true"),
            Some("GET, POST, PATCH"),
            Some("Content-Type, X-Goog-AuthUser"),
            Some("3600"),
        );
        if pf3.allowed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        max_age_sum += pf3.max_age as i64;
        digest = fnv1a_byte(digest, if pf3.allowed { 1 } else { 0 });
        digest = fnv1a_str(digest, &pf3.max_age.to_string());

        let pf4 = check_cors_preflight(
            "https://meet.google.com",
            CredentialsMode::Include,
            "DELETE",
            &["X-Custom"],
            Some("https://meet.google.com"),
            Some("true"),
            Some("*"),
            Some("*"),
            Some("600"),
        );
        if pf4.allowed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        max_age_sum += pf4.max_age as i64;
        digest = fnv1a_byte(digest, if pf4.allowed { 1 } else { 0 });
        digest = fnv1a_str(digest, &pf4.max_age.to_string());
    }

    println!("mode=cors");
    println!("rounds={}", rounds);
    println!("allowed={}", allowed_count);
    println!("blocked={}", blocked_count);
    println!("max_age_sum={}", max_age_sum);
    println!("fnv1a64={:016x}", digest);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: csp-bench-rust <csp|cors>");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "csp" => bench_csp(2000),
        "cors" => bench_cors(20000),
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
