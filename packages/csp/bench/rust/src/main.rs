//! Idiomatic zero-dependency Rust reference implementation of W3C CSP Level 3 +
//! WHATWG Fetch CORS for head-to-head benchmarking against `packages/csp`.
//! Compiled with `cargo build --release`.

use std::env;

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
    Host(Option<String>, String, Option<i32>, bool, String),
}

struct CspDirective {
    name: String,
    sources: Vec<SourceExpression>,
    #[allow(dead_code)]
    raw_values: Vec<String>,
}

struct CspPolicy {
    directives: Vec<CspDirective>,
    #[allow(dead_code)]
    upgrade_insecure_requests: bool,
    #[allow(dead_code)]
    block_all_mixed_content: bool,
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
    #[allow(dead_code)]
    SameOrigin,
    Include,
}

enum Origin {
    Opaque,
    Tuple(String, String, i32),
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
fn is_csp_ws(b: u8) -> bool {
    b == b' ' || b == b'\t' || b == 12
}

#[inline]
fn default_port(scheme: &str) -> i32 {
    match scheme {
        "http" | "ws" => 80,
        "https" | "wss" => 443,
        "ftp" => 21,
        _ => -1,
    }
}

fn is_valid_scheme(s: &str) -> bool {
    let bytes = s.as_bytes();
    if bytes.is_empty() || !bytes[0].is_ascii_alphabetic() {
        return false;
    }
    bytes[1..]
        .iter()
        .all(|&b| b.is_ascii_alphanumeric() || b == b'+' || b == b'-' || b == b'.')
}

fn parse_port(s: &str) -> i32 {
    if s.is_empty() || s.len() > 5 {
        return -1;
    }
    let mut acc: i32 = 0;
    for &b in s.as_bytes() {
        if !b.is_ascii_digit() {
            return -1;
        }
        acc = acc * 10 + (b - b'0') as i32;
    }
    if acc > 65535 { -1 } else { acc }
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
    let bytes = tok.as_bytes();
    let n = bytes.len();
    if n == 0 {
        return None;
    }
    if n >= 2 && bytes[0] == b'\'' && bytes[n - 1] == b'\'' {
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
    if tok == "*" {
        return Some(SourceExpression::Host(
            None,
            "*".to_string(),
            None,
            false,
            String::new(),
        ));
    }
    if bytes[n - 1] == b':' && !tok.contains('/') {
        let sch = &tok[..n - 1];
        if is_valid_scheme(sch) {
            return Some(SourceExpression::Scheme(sch.to_ascii_lowercase()));
        }
        return None;
    }

    let mut opt_scheme = None;
    let mut rest = tok;
    if let Some(sep) = tok.find("://") {
        let sch = &tok[..sep];
        if !is_valid_scheme(sch) {
            return None;
        }
        opt_scheme = Some(sch.to_ascii_lowercase());
        rest = &tok[sep + 3..];
    }
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
                let p = parse_port(pstr);
                if p < 0 {
                    return None;
                }
                (h, Some(p), false)
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
            let p = parse_port(pstr);
            if p < 0 {
                return None;
            }
            (h, Some(p), false)
        }
    } else {
        (hostport.to_ascii_lowercase(), None, false)
    };

    if host.is_empty() {
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
        if b == 0 || b == 10 || b == 13 || b == 127 || b > 127 || (b < 32 && b != 9 && b != 12) {
            return Err("invalid header byte");
        }
    }
    let mut directives: Vec<CspDirective> = Vec::new();
    let mut upgrade_insecure_requests = false;
    let mut block_all_mixed_content = false;

    for raw in header.split(';') {
        let trimmed = raw.trim_matches(|c: char| is_csp_ws(c as u8));
        if trimmed.is_empty() {
            continue;
        }
        let mut iter = trimmed.split(|c: char| is_csp_ws(c as u8)).filter(|s| !s.is_empty());
        let name_raw = match iter.next() {
            Some(n) => n,
            None => continue,
        };
        let name = name_raw.to_ascii_lowercase();
        if directives.iter().any(|d| d.name == name) {
            continue;
        }
        let parse_sources = is_source_list_directive(&name);
        let mut sources = Vec::new();
        let mut raw_values = Vec::new();
        for tok in iter {
            raw_values.push(tok.to_string());
            if parse_sources {
                if let Some(expr) = parse_source_expression(tok) {
                    sources.push(expr);
                }
            }
        }
        if name == "upgrade-insecure-requests" {
            upgrade_insecure_requests = true;
        } else if name == "block-all-mixed-content" {
            block_all_mixed_content = true;
        }
        directives.push(CspDirective {
            name,
            sources,
            raw_values,
        });
    }
    Ok(CspPolicy {
        directives,
        upgrade_insecure_requests,
        block_all_mixed_content,
    })
}

struct UrlParts<'a> {
    scheme: String,
    host: String,
    port: i32,
    path: &'a str,
    has_host: bool,
}

fn parse_url_parts(raw: &str) -> UrlParts<'_> {
    let s = raw.trim_matches(|c: char| is_csp_ws(c as u8));
    let colon = match s.find(':') {
        Some(c) if c > 0 => c,
        _ => {
            return UrlParts {
                scheme: String::new(),
                host: String::new(),
                port: -1,
                path: s,
                has_host: false,
            }
        }
    };
    let scheme = s[..colon].to_ascii_lowercase();
    let rest = &s[colon + 1..];
    if !rest.starts_with("//") {
        return UrlParts {
            scheme,
            host: String::new(),
            port: -1,
            path: rest,
            has_host: false,
        };
    }
    let after = &rest[2..];
    let auth_end = after
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(after.len());
    let auth = &after[..auth_end];
    let mut path = if auth_end < after.len() && after.as_bytes()[auth_end] == b'/' {
        let mut p = &after[auth_end..];
        if let Some(q) = p.find('?') {
            p = &p[..q];
        }
        if let Some(h) = p.find('#') {
            p = &p[..h];
        }
        p
    } else {
        "/"
    };
    if path.is_empty() {
        path = "/";
    }
    let hostport = match auth.find('@') {
        Some(at) => &auth[at + 1..],
        None => auth,
    };
    let mut host = String::new();
    let mut port = default_port(&scheme);
    if !hostport.is_empty() {
        if hostport.starts_with('[') {
            if let Some(rb) = hostport.find(']') {
                host = hostport[..=rb].to_ascii_lowercase();
                if let Some(pstr) = hostport[rb + 1..].strip_prefix(':') {
                    let p = parse_port(pstr);
                    if p >= 0 {
                        port = p;
                    }
                }
            }
        } else if let Some(pc) = hostport.find(':') {
            host = hostport[..pc].to_ascii_lowercase();
            let p = parse_port(&hostport[pc + 1..]);
            if p >= 0 {
                port = p;
            }
        } else {
            host = hostport.to_ascii_lowercase();
        }
    }
    let has_host = !host.is_empty();
    UrlParts {
        scheme,
        host,
        port,
        path,
        has_host,
    }
}

fn scheme_matches(expr_scheme: &str, target_scheme: &str) -> bool {
    expr_scheme == target_scheme
        || (expr_scheme == "http" && target_scheme == "https")
        || (expr_scheme == "ws" && target_scheme == "wss")
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

fn has_path_traversal(path: &str) -> bool {
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
    for seg in path.split('/') {
        if seg.is_empty() {
            continue;
        }
        let sb = seg.as_bytes();
        let mut p = 0;
        let mut dots = 0;
        let mut all_dots = true;
        while p < sb.len() {
            if sb[p] == b'.' {
                dots += 1;
                p += 1;
            } else if p + 2 < sb.len()
                && sb[p] == b'%'
                && sb[p + 1] == b'2'
                && (sb[p + 2] == b'e' || sb[p + 2] == b'E')
            {
                dots += 1;
                p += 3;
            } else {
                all_dots = false;
                break;
            }
        }
        if all_dots && dots == 2 {
            return true;
        }
    }
    false
}

fn path_matches(expr_path: &str, target_path: &str) -> bool {
    if expr_path.is_empty() {
        return true;
    }
    if has_path_traversal(target_path) {
        return false;
    }
    if expr_path.ends_with('/') {
        target_path.starts_with(expr_path)
    } else {
        expr_path == target_path
    }
}

fn expr_matches_url(expr: &SourceExpression, page: &UrlParts<'_>, target: &UrlParts<'_>) -> bool {
    match expr {
        SourceExpression::NoneExpr => false,
        SourceExpression::SelfExpr => {
            if !page.has_host || !target.has_host {
                return false;
            }
            if !scheme_matches(&page.scheme, &target.scheme) || page.host != target.host {
                return false;
            }
            if page.port == target.port {
                return true;
            }
            (page.scheme == "http" && target.scheme == "https" && page.port == 80 && target.port == 443)
                || (page.scheme == "ws" && target.scheme == "wss" && page.port == 80 && target.port == 443)
        }
        SourceExpression::Scheme(s) => scheme_matches(s, &target.scheme),
        SourceExpression::Host(opt_scheme, host_pat, opt_port, port_wild, path_pat) => {
            if opt_scheme.is_none() && opt_port.is_none() && !*port_wild && host_pat == "*" && path_pat.is_empty() {
                if matches!(
                    target.scheme.as_str(),
                    "data" | "blob" | "filesystem" | "javascript" | "about"
                ) {
                    return false;
                }
                return matches!(target.scheme.as_str(), "http" | "https" | "ws" | "wss")
                    || (!page.scheme.is_empty() && target.scheme == page.scheme);
            }
            if !target.has_host {
                return false;
            }
            let eff_scheme = opt_scheme.as_deref().unwrap_or(&page.scheme);
            if !eff_scheme.is_empty() && !scheme_matches(eff_scheme, &target.scheme) {
                return false;
            }
            if !host_matches(host_pat, &target.host) {
                return false;
            }
            if !*port_wild {
                if let Some(ep) = opt_port {
                    if target.port != *ep {
                        let up = (eff_scheme == "http" && target.scheme == "https" && *ep == 80 && target.port == 443)
                            || (eff_scheme == "ws" && target.scheme == "wss" && *ep == 80 && target.port == 443);
                        if !up {
                            return false;
                        }
                    }
                } else {
                    let def_p = default_port(&target.scheme);
                    if def_p >= 0 && target.port != def_p {
                        return false;
                    }
                }
            }
            path_matches(path_pat, target.path)
        }
        _ => false,
    }
}

fn find_dir<'a>(policy: &'a CspPolicy, name: &str) -> Option<&'a CspDirective> {
    policy.directives.iter().find(|d| d.name == name)
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
        "frame-src" => find_dir(policy, "child-src").or_else(|| find_dir(policy, "default-src")),
        "child-src" | "script-src" | "style-src" | "img-src" | "connect-src" | "media-src"
        | "font-src" | "object-src" | "manifest-src" | "prefetch-src" => {
            find_dir(policy, "default-src")
        }
        _ => None,
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

    let page = parse_url_parts(page_origin);
    let target = parse_url_parts(target_url);
    for expr in &dir.sources {
        if expr_matches_url(expr, &page, &target) {
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
// WHATWG Fetch CORS
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

fn parse_origin(url: &str) -> Origin {
    let s = url.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("null") {
        return Origin::Opaque;
    }
    let sep = match s.find("://") {
        Some(i) if i > 0 => i,
        _ => return Origin::Opaque,
    };
    let scheme = s[..sep].to_ascii_lowercase();
    let def_port = default_port(&scheme);
    if def_port < 0 {
        return Origin::Opaque;
    }
    let after = &s[sep + 3..];
    let auth_end = after
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(after.len());
    let auth = &after[..auth_end];
    if auth.is_empty() || auth.bytes().any(|b| b <= 32 || b == 127) {
        return Origin::Opaque;
    }
    let hp = match auth.find('@') {
        Some(at) => &auth[at + 1..],
        None => auth,
    };
    if hp.is_empty() {
        return Origin::Opaque;
    }
    let (host, port) = if hp.starts_with('[') {
        let rb = match hp.find(']') {
            Some(r) => r,
            None => return Origin::Opaque,
        };
        let h = hp[..=rb].to_ascii_lowercase();
        let tail = &hp[rb + 1..];
        if tail.is_empty() {
            (h, def_port)
        } else if let Some(pstr) = tail.strip_prefix(':') {
            let p = parse_port(pstr);
            if p <= 0 {
                return Origin::Opaque;
            }
            (h, p)
        } else {
            return Origin::Opaque;
        }
    } else if let Some(colon) = hp.find(':') {
        let h = hp[..colon].to_ascii_lowercase();
        let p = parse_port(&hp[colon + 1..]);
        if p <= 0 {
            return Origin::Opaque;
        }
        (h, p)
    } else {
        (hp.to_ascii_lowercase(), def_port)
    };
    if host.is_empty() {
        return Origin::Opaque;
    }
    Origin::Tuple(scheme, host, port)
}

fn origin_equals(a: &Origin, b: &Origin) -> bool {
    match (a, b) {
        (Origin::Tuple(sa, ha, pa), Origin::Tuple(sb, hb, pb)) => sa == sb && ha == hb && pa == pb,
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
        .map(|s| s.trim().parse::<i32>().unwrap_or(0).max(0))
        .unwrap_or(0);
    CorsPreflightDecision {
        allowed: true,
        max_age: parsed_max_age,
    }
}

fn mix_decision(acc: i64, d: &CspDecision) -> i64 {
    let b = if d.allowed { 1 } else { 0 };
    let vl = d.violated_directive.len() as i64;
    let el = d.effective_directive.len() as i64;
    let ml = d.matched_source.as_ref().map(|s| s.len() as i64).unwrap_or(0);
    (acc * 131 + b * 17 + vl * 7 + el * 3 + ml) % 1_000_000_007
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

    let mut checksum: i64 = 0;
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
                check_source(&p, "script-src", orig, "https://static.figma.com/webpack/main.js", "", &[("sha256", "FigMaHash01=")], true),
                check_source(&p, "script-src", orig, "https://evil.example/xss.js", "", &[], false),
                check_source(&p, "img-src", orig, "https://avatars.githubusercontent.com/u/42", "", &[], true),
                check_source(&p, "img-src", orig, "data:image/png;base64,AA==", "", &[], true),
                check_source(&p, "connect-src", orig, "wss://alive.github.com/ws", "", &[], true),
                check_source(&p, "worker-src", orig, "https://github.com/assets-cdn/worker/../escape.js", "", &[], true),
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
                checksum = mix_decision(checksum, d);
            }
        }
    }

    println!("mode=csp");
    println!("rounds={}", rounds);
    println!("directives={}", total_directives);
    println!("sources={}", total_sources);
    println!("allowed={}", allowed_count);
    println!("blocked={}", blocked_count);
    println!("checksum={}", checksum);
}

fn bench_cors(rounds: i32) {
    let mut checksum: i64 = 0;
    let mut allowed_count: i32 = 0;
    let mut blocked_count: i32 = 0;
    let mut max_age_sum: i64 = 0;

    for _ in 0..rounds {
        let o1 = parse_origin("https://App.Example.COM:443/v1/feed");
        let o2 = parse_origin("https://app.example.com");
        let o3 = parse_origin("null");
        if origin_equals(&o1, &o2) && !origin_equals(&o3, &o3) {
            allowed_count += 1;
            checksum = (checksum * 131 + 11) % 1_000_000_007;
        } else {
            blocked_count += 1;
        }

        let safe1 = is_cors_safelisted_method("POST")
            && is_cors_safelisted_request_header("Content-Type", "text/plain; charset=utf-8");
        let safe2 = is_cors_safelisted_request_header("Content-Type", "application/json");
        if safe1 && !safe2 {
            allowed_count += 1;
            checksum = (checksum * 131 + 23) % 1_000_000_007;
        } else {
            blocked_count += 1;
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
        checksum = (checksum * 131 + r1.exposed_headers.len() as i64) % 1_000_000_007;

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
        checksum = (checksum * 131 + if r2.allowed { 1 } else { 2 }) % 1_000_000_007;

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
        checksum = (checksum * 131 + if r3.wildcard_exposed { 5 } else { 3 }) % 1_000_000_007;

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
        checksum = (checksum * 131 + if r4.allowed { 1 } else { 7 }) % 1_000_000_007;

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
        checksum = (checksum * 131 + pf1.max_age as i64 + if pf1.allowed { 1 } else { 9 })
            % 1_000_000_007;

        let pf2 = check_cors_preflight(
            "https://www.figma.com",
            CredentialsMode::Omit,
            "PUT",
            &["X-Figma-Token", "Authorization"],
            Some("*"),
            None,
            Some("GET, POST, PUT, DELETE"),
            Some("*, Authorization"),
            Some("86400"),
        );
        if pf2.allowed {
            allowed_count += 1;
        } else {
            blocked_count += 1;
        }
        max_age_sum += pf2.max_age as i64;
        checksum = (checksum * 131 + pf2.max_age as i64 + if pf2.allowed { 1 } else { 9 })
            % 1_000_000_007;

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
        checksum = (checksum * 131 + pf3.max_age as i64 + if pf3.allowed { 1 } else { 9 })
            % 1_000_000_007;

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
        checksum = (checksum * 131 + pf4.max_age as i64 + if pf4.allowed { 1 } else { 9 })
            % 1_000_000_007;
    }

    println!("mode=cors");
    println!("rounds={}", rounds);
    println!("allowed={}", allowed_count);
    println!("blocked={}", blocked_count);
    println!("max_age_sum={}", max_age_sum);
    println!("checksum={}", checksum);
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
