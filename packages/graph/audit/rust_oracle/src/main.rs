//! Differential oracle for the `packages/graph` red-team audit.
//!
//! `graph_oracle fuzz <seed> <cases>` generates exactly the same random graphs as
//! `packages/graph/audit/runner` (same LCG, same draw order) and prints one canonical
//! line per (case, section). Lines named `X` are the ground truth the Pion runner must
//! reproduce byte-for-byte; lines named `X_pg` are what petgraph =0.8.3 itself returns when
//! that differs from ground truth (an exact i128 / brute-force reference), so the report can
//! say where *upstream* is wrong as well.
use petgraph::algo::tred::{dag_to_toposorted_adjacency_list, dag_transitive_reduction_closure};
use petgraph::algo::{
    astar, bellman_ford, bridges, dijkstra, dinics, dominators,
    find_negative_cycle, floyd_warshall, is_cyclic_directed, kosaraju_scc, min_spanning_tree,
    min_spanning_tree_prim, tarjan_scc, toposort,
};
use petgraph::data::Element;
use petgraph::graph::{DiGraph, NodeIndex, UnGraph};
use petgraph::visit::{EdgeRef, IntoNeighbors, IntoNodeReferences, NodeCount};
use petgraph::Direction::{Incoming, Outgoing};
use std::env;

const HALF: i64 = i64::MAX / 2;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, m: u64) -> u64 {
        self.next() % m
    }
}

struct Gen {
    n: usize,
    wkind: u64,
    edges: Vec<(usize, usize, i64)>,
}

fn weight(r: &mut Rng, k: u64) -> i64 {
    match k {
        0 => r.below(10) as i64,
        1 => r.below(13) as i64 - 3,
        2 => {
            if r.below(2) == 0 {
                HALF - r.below(3) as i64
            } else {
                r.below(10) as i64
            }
        }
        3 => r.below(2) as i64,
        _ => r.below(1000) as i64,
    }
}

fn gen(r: &mut Rng) -> Gen {
    let n = if r.below(8) == 0 { 20 + r.below(21) } else { 1 + r.below(10) } as usize;
    let m = r.below(3 * n as u64 + 1) as usize;
    let wkind = r.below(5);
    let mut edges = Vec::with_capacity(m);
    let (mut pu, mut pv) = (0usize, 0usize);
    for i in 0..m {
        if i > 0 && r.below(4) == 0 {
        } else {
            pu = r.below(n as u64) as usize;
            pv = r.below(n as u64) as usize;
        }
        let w = weight(r, wkind);
        edges.push((pu, pv, w));
    }
    Gen { n, wkind, edges }
}

fn join<T: ToString>(v: &[T]) -> String {
    v.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")
}

fn digraph(g: &Gen) -> DiGraph<(), i64> {
    let mut d = DiGraph::new();
    for _ in 0..g.n {
        d.add_node(());
    }
    for &(u, v, w) in &g.edges {
        d.add_edge(NodeIndex::new(u), NodeIndex::new(v), w);
    }
    d
}

fn ungraph(g: &Gen) -> UnGraph<(), i64> {
    let mut d = UnGraph::new_undirected();
    for _ in 0..g.n {
        d.add_node(());
    }
    for &(u, v, w) in &g.edges {
        d.add_edge(NodeIndex::new(u), NodeIndex::new(v), w);
    }
    d
}

fn canon_sccs(s: &[Vec<NodeIndex>]) -> String {
    let mut comps: Vec<Vec<usize>> = s
        .iter()
        .map(|c| {
            let mut v: Vec<usize> = c.iter().map(|x| x.index()).collect();
            v.sort();
            v
        })
        .collect();
    comps.sort();
    comps.iter().map(|c| join(c)).collect::<Vec<_>>().join("|")
}

fn scc_rev_topo_ok(g: &Gen, s: &[Vec<NodeIndex>]) -> bool {
    let mut pos = vec![0usize; g.n];
    for (i, c) in s.iter().enumerate() {
        for x in c {
            pos[x.index()] = i;
        }
    }
    g.edges.iter().all(|&(u, v, _)| pos[u] >= pos[v])
}

fn on_cycle(g: &Gen) -> Vec<bool> {
    let d = digraph(g);
    let mut res = vec![false; g.n];
    for c in tarjan_scc(&d) {
        if c.len() > 1 {
            for x in c {
                res[x.index()] = true;
            }
        }
    }
    for &(u, v, _) in &g.edges {
        if u == v {
            res[u] = true;
        }
    }
    res
}

/// Exact i128 Floyd-Warshall with explicit reachability; None = negative cycle.
fn floyd_ref(g: &Gen) -> Option<Vec<Option<i128>>> {
    let n = g.n;
    let mut d: Vec<Option<i128>> = vec![None; n * n];
    for i in 0..n {
        d[i * n + i] = Some(0);
    }
    for &(u, v, w) in &g.edges {
        let w = w as i128;
        let x = &mut d[u * n + v];
        if x.map_or(true, |c| w < c) {
            *x = Some(w);
        }
    }
    for k in 0..n {
        for i in 0..n {
            if let Some(a) = d[i * n + k] {
                for j in 0..n {
                    if let Some(b) = d[k * n + j] {
                        let c = a + b;
                        if d[i * n + j].map_or(true, |x| c < x) {
                            d[i * n + j] = Some(c);
                        }
                    }
                }
            }
        }
    }
    for i in 0..n {
        if d[i * n + i].unwrap() < 0 {
            return None;
        }
    }
    Some(d)
}

fn min_w(g: &Gen, u: usize, v: usize) -> Option<i64> {
    g.edges.iter().filter(|e| e.0 == u && e.1 == v).map(|e| e.2).min()
}

fn neg_cycle_valid(g: &Gen, cyc: &[usize]) -> bool {
    if cyc.is_empty() {
        return false;
    }
    let mut sum: i128 = 0;
    for i in 0..cyc.len() {
        let a = cyc[i];
        let b = cyc[(i + 1) % cyc.len()];
        match min_w(g, a, b) {
            Some(w) => sum += w as i128,
            None => return false,
        }
    }
    sum < 0
}

fn components(n: usize, edges: &[(usize, usize)], skip_node: Option<usize>) -> usize {
    let mut p: Vec<usize> = (0..n).collect();
    fn f(p: &mut Vec<usize>, x: usize) -> usize {
        let mut x = x;
        while p[x] != x {
            p[x] = p[p[x]];
            x = p[x];
        }
        x
    }
    let mut c = n - skip_node.map_or(0, |_| 1);
    for &(u, v) in edges {
        if Some(u) == skip_node || Some(v) == skip_node {
            continue;
        }
        let (a, b) = (f(&mut p, u), f(&mut p, v));
        if a != b {
            p[a] = b;
            c -= 1;
        }
    }
    c
}

fn run_case(seed: u64, case: u64) {
    let mut r = Rng(seed ^ (case + 1).wrapping_mul(0x9E3779B97F4A7C15));
    r.next();
    r.next();
    let g = gen(&mut r);
    let ug = gen(&mut r);
    let dag_src = gen(&mut r);
    let p = |sec: &str, s: String| println!("c{case} {sec} {s}");
    let n = g.n;
    let d = digraph(&g);

    // ---------- ops: random add/remove churn on DiGraph and UnGraph ----------
    {
        let mut dg: DiGraph<(), i64> = DiGraph::new();
        let mut ugr: UnGraph<(), i64> = UnGraph::new_undirected();
        let (mut ms, mut lay, mut ord) = (Vec::new(), Vec::new(), Vec::new());
        let (mut ums, mut ulay) = (Vec::new(), Vec::new());
        for step in 0..40i64 {
            let op = r.below(10);
            let nc = dg.node_count() as u64;
            let ec = dg.edge_count() as u64;
            match op {
                0..=2 => {
                    dg.add_node(());
                    ugr.add_node(());
                }
                3..=6 => {
                    if nc > 0 {
                        let u = NodeIndex::new(r.below(nc) as usize);
                        let v = NodeIndex::new(r.below(nc) as usize);
                        dg.add_edge(u, v, step);
                        ugr.add_edge(u, v, step);
                    }
                }
                7..=8 => {
                    if ec > 0 {
                        // pick the k-th edge by (unique) weight so both libraries remove the
                        // same logical edge even when their EdgeIndex layouts diverged
                        let k = r.below(ec) as usize;
                        let mut ws: Vec<i64> = dg.edge_weights().copied().collect();
                        ws.sort();
                        let w = ws[k];
                        let e = dg.edge_indices().find(|&e| dg[e] == w).unwrap();
                        dg.remove_edge(e);
                        let e = ugr.edge_indices().find(|&e| ugr[e] == w).unwrap();
                        ugr.remove_edge(e);
                    }
                }
                _ => {
                    if nc > 0 {
                        let v = NodeIndex::new(r.below(nc) as usize);
                        dg.remove_node(v);
                        ugr.remove_node(v);
                    }
                }
            }
            // multiset view (layout independent)
            let mut tri: Vec<(usize, usize, i64)> = dg
                .edge_references()
                .map(|e| (e.source().index(), e.target().index(), *e.weight()))
                .collect();
            tri.sort();
            let mut s = format!("{}:{}:", dg.node_count(), dg.edge_count());
            s += &tri.iter().map(|t| format!("{}>{}={}", t.0, t.1, t.2)).collect::<Vec<_>>().join(",");
            for (v, _) in dg.node_references() {
                let mut o: Vec<usize> = dg.neighbors_directed(v, Outgoing).map(|x| x.index()).collect();
                let mut i: Vec<usize> = dg.neighbors_directed(v, Incoming).map(|x| x.index()).collect();
                o.sort();
                i.sort();
                s += &format!(";{}<{}", join(&o), join(&i));
            }
            ms.push(s);
            lay.push(
                dg.edge_references()
                    .map(|e| format!("{}>{}={}", e.source().index(), e.target().index(), e.weight()))
                    .collect::<Vec<_>>()
                    .join(","),
            );
            ord.push(
                dg.node_references()
                    .map(|(v, _)| join(&dg.neighbors_directed(v, Outgoing).map(|x| x.index()).collect::<Vec<_>>()))
                    .collect::<Vec<_>>()
                    .join(";"),
            );
            let mut ut: Vec<(usize, usize, i64)> = ugr
                .edge_references()
                .map(|e| {
                    let (a, b) = (e.source().index(), e.target().index());
                    (a.min(b), a.max(b), *e.weight())
                })
                .collect();
            ut.sort();
            let mut s = format!("{}:{}:", ugr.node_count(), ugr.edge_count());
            s += &ut.iter().map(|t| format!("{}-{}={}", t.0, t.1, t.2)).collect::<Vec<_>>().join(",");
            for (v, _) in ugr.node_references() {
                let mut o: Vec<usize> = ugr.neighbors(v).map(|x| x.index()).collect();
                o.sort();
                s += &format!(";{}", join(&o));
            }
            ums.push(s);
            ulay.push(
                ugr.edge_references()
                    .map(|e| format!("{}-{}={}", e.source().index(), e.target().index(), e.weight()))
                    .collect::<Vec<_>>()
                    .join(","),
            );
        }
        p("ops_ms", ms.join("/"));
        p("ops_lay", lay.join("/"));
        p("ops_ord", ord.join("/"));
        p("uops_ms", ums.join("/"));
        p("uops_lay", ulay.join("/"));
    }

    // ---------- SCC ----------
    let t = tarjan_scc(&d);
    let k = kosaraju_scc(&d);
    p(
        "scc",
        format!("{} inv={}", canon_sccs(&t), scc_rev_topo_ok(&g, &t)),
    );
    p(
        "kscc",
        format!("{} inv={}", canon_sccs(&k), scc_rev_topo_ok(&g, &k)),
    );

    // ---------- toposort / cycles ----------
    let cyc = is_cyclic_directed(&d);
    let oc = on_cycle(&g);
    let topo = match toposort(&d, None) {
        Ok(o) => {
            let mut pos = vec![0; n];
            for (i, x) in o.iter().enumerate() {
                pos[x.index()] = i;
            }
            format!("ok valid={}", g.edges.iter().all(|&(u, v, _)| pos[u] < pos[v]))
        }
        Err(c) => format!("cycle node_on_cycle={}", oc[c.node_id().index()]),
    };
    p("topo", format!("cyclic={cyc} {topo}"));

    // ---------- dominators + brute-force dominance frontiers ----------
    {
        let dm = dominators::simple_fast(&d, NodeIndex::new(0));
        let mut idom = vec![-1i64; n];
        let mut reach = vec![false; n];
        for v in 0..n {
            if v == 0 {
                idom[0] = 0;
                reach[0] = true;
            } else if let Some(x) = dm.immediate_dominator(NodeIndex::new(v)) {
                idom[v] = x.index() as i64;
                reach[v] = true;
            }
        }
        p("dom", join(&idom));
        let dominates = |a: usize, b: usize| -> bool {
            if !reach[b] {
                return false;
            }
            let mut c = b;
            loop {
                if c == a {
                    return true;
                }
                if c == 0 {
                    return false;
                }
                c = idom[c] as usize;
            }
        };
        let mut df = Vec::new();
        for x in 0..n {
            let mut s: Vec<usize> = Vec::new();
            if reach[x] {
                for y in 0..n {
                    if !reach[y] {
                        continue;
                    }
                    let strict = x != y && dominates(x, y);
                    if strict {
                        continue;
                    }
                    if g.edges.iter().any(|&(pp, yy, _)| yy == y && reach[pp] && dominates(x, pp)) {
                        s.push(y);
                    }
                }
            }
            df.push(join(&s));
        }
        p("df", df.join("|"));
    }

    let small_nonneg = matches!(g.wkind, 0 | 3 | 4);
    // ---------- Dijkstra ----------
    if small_nonneg {
        let m = dijkstra(&d, NodeIndex::new(0), None, |e| *e.weight());
        let v: Vec<String> = (0..n)
            .map(|i| m.get(&NodeIndex::new(i)).map_or("-".into(), |x| x.to_string()))
            .collect();
        p("dij", v.join(","));
    }
    // ---------- Bellman-Ford (f64 is exact for these small integers) ----------
    if g.wkind != 2 {
        let mut fd: DiGraph<(), f64> = DiGraph::new();
        for _ in 0..n {
            fd.add_node(());
        }
        for &(u, v, w) in &g.edges {
            fd.add_edge(NodeIndex::new(u), NodeIndex::new(v), w as f64);
        }
        let bf = match bellman_ford(&fd, NodeIndex::new(0)) {
            Ok(paths) => paths
                .distances
                .iter()
                .map(|x| if x.is_infinite() { "-".into() } else { format!("{}", *x as i64) })
                .collect::<Vec<String>>()
                .join(","),
            Err(_) => "negcycle".into(),
        };
        p("bf", bf);
        match find_negative_cycle(&fd, NodeIndex::new(0)) {
            Some(c) => {
                let c: Vec<usize> = c.iter().map(|x| x.index()).collect();
                p("negcyc", "some valid=true".into());
                if !neg_cycle_valid(&g, &c) {
                    p("negcyc_pg", format!("some valid=false cyc={}", join(&c)));
                }
            }
            None => p("negcyc", "none".into()),
        }
    }
    // ---------- Floyd-Warshall: exact reference vs petgraph ----------
    {
        let truth = match floyd_ref(&g) {
            None => "negcycle".to_string(),
            Some(m) => {
                if m.iter().any(|x| x.map_or(false, |v| v > i64::MAX as i128 || v < i64::MIN as i128)) {
                    "overflow".to_string()
                } else {
                    m.iter().map(|x| x.map_or("-".into(), |v| v.to_string())).collect::<Vec<_>>().join(",")
                }
            }
        };
        p("fw", truth.clone());
        let pg = match floyd_warshall(&d, |e| *e.weight()) {
            Err(_) => "negcycle".to_string(),
            Ok(map) => {
                let mut v = Vec::new();
                for i in 0..n {
                    for j in 0..n {
                        let x = map[&(NodeIndex::new(i), NodeIndex::new(j))];
                        v.push(if x == i64::MAX { "-".into() } else { x.to_string() });
                    }
                }
                v.join(",")
            }
        };
        if pg != truth {
            p("fw_pg", pg);
        }
    }
    // ---------- A* with an admissible but inconsistent heuristic ----------
    {
        let goal = n - 1;
        // h(v) = floor(true_dist(v, goal) * r / 4), r in 0..=4  (always <= true distance)
        let fr = floyd_ref(&g);
        let mut h = vec![0i64; n];
        for v in 0..n {
            let rr = r.below(5) as i128;
            if let Some(m) = &fr {
                if let Some(td) = m[v * n + goal] {
                    h[v] = (td * rr / 4) as i64;
                }
            }
        }
        if small_nonneg {
            let truth = fr.as_ref().unwrap()[goal];
            let t = match truth {
                Some(c) => format!("cost={c} path_ok=true"),
                None => "none".into(),
            };
            p("astar", t.clone());
            let pg = match astar(&d, NodeIndex::new(0), |x| x.index() == goal, |e| *e.weight(), |x| h[x.index()]) {
                Some((c, path)) => {
                    let ok = path.windows(2).map(|w| min_w(&g, w[0].index(), w[1].index()).unwrap()).sum::<i64>() == c;
                    format!("cost={c} path_ok={ok}")
                }
                None => "none".into(),
            };
            if pg != t {
                p("astar_pg", pg);
            }
        }
    }

    // ---------- MST (undirected) ----------
    {
        let u = ungraph(&ug);
        let tot = |it: &mut dyn Iterator<Item = Element<(), i64>>| -> String {
            let mut s: i128 = 0;
            let mut c = 0;
            for e in it {
                if let Element::Edge { weight, .. } = e {
                    s += weight as i128;
                    c += 1;
                }
            }
            if s > i64::MAX as i128 || s < i64::MIN as i128 {
                "overflow".into()
            } else {
                format!("{s}/{c}")
            }
        };
        let k = tot(&mut min_spanning_tree(&u));
        p("mst", k.clone());
        let pr = tot(&mut min_spanning_tree_prim(&u));
        if pr != k {
            p("mst_prim_pg", pr);
        }
    }

    // ---------- Max flow (capacities = max(w, 0)) ----------
    if n >= 2 {
        let mut fg: DiGraph<(), u64> = DiGraph::new();
        for _ in 0..n {
            fg.add_node(());
        }
        for &(u, v, w) in &g.edges {
            fg.add_edge(NodeIndex::new(u), NodeIndex::new(v), w.max(0) as u64);
        }
        // ground truth in u128 (cannot overflow here); petgraph's own u64 answer reported as flow_pg
        let mut fg128: DiGraph<(), u128> = DiGraph::new();
        for _ in 0..n {
            fg128.add_node(());
        }
        for &(u, v, w) in &g.edges {
            fg128.add_edge(NodeIndex::new(u), NodeIndex::new(v), w.max(0) as u128);
        }
        let (f128, _) = dinics(&fg128, NodeIndex::new(0), NodeIndex::new(n - 1));
        let s = if f128 > i64::MAX as u128 { "overflow".to_string() } else { format!("{f128} cert=true") };
        p("flow", s.clone());
        let (f, _) = dinics(&fg, NodeIndex::new(0), NodeIndex::new(n - 1));
        if f as u128 != f128 {
            p("flow_pg", format!("{f} (u64 wrapped; true max flow {f128})"));
        }
    }

    // ---------- Bridges / articulation points: brute force truth + petgraph ----------
    {
        let u = ungraph(&ug);
        let ep: Vec<(usize, usize)> = ug.edges.iter().map(|e| (e.0, e.1)).collect();
        let base = components(ug.n, &ep, None);
        let mut br = Vec::new();
        for i in 0..ep.len() {
            if ep[i].0 == ep[i].1 {
                continue;
            }
            let mut rest = ep.clone();
            rest.remove(i);
            if components(ug.n, &rest, None) > base {
                br.push(i);
            }
        }
        p("br", join(&br));
        let mut pg: Vec<usize> = bridges(&u).map(|e| e.id().index()).collect();
        pg.sort();
        if pg != br {
            p("br_pg", join(&pg));
        }
        let mut ap = Vec::new();
        for v in 0..ug.n {
            if components(ug.n, &ep, Some(v)) > base {
                ap.push(v);
            }
        }
        p("ap", join(&ap));
        let s = petgraph::algo::articulation_points::articulation_points(&u);
        let mut pa: Vec<usize> = s.iter().map(|x| x.index()).collect();
        pa.sort();
        if pa != ap {
            p("ap_pg", join(&pa));
        }
    }

    // ---------- Transitive reduction / closure on a DAG ----------
    {
        let mut dd: DiGraph<(), ()> = DiGraph::new();
        for _ in 0..dag_src.n {
            dd.add_node(());
        }
        for &(a, b, _) in &dag_src.edges {
            if a != b {
                dd.add_edge(NodeIndex::new(a.min(b)), NodeIndex::new(a.max(b)), ());
            }
        }
        let topo = toposort(&dd, None).unwrap();
        let (list, _rev) = dag_to_toposorted_adjacency_list::<_, u32>(&dd, &topo);
        let (red, clo) = dag_transitive_reduction_closure(&list);
        let back = |l: &petgraph::adj::UnweightedList<u32>| -> String {
            let mut e: Vec<(usize, usize)> = Vec::new();
            for a in 0..l.node_count() as u32 {
                for b in l.neighbors(a) {
                    e.push((topo[a as usize].index(), topo[b as usize].index()));
                }
            }
            e.sort();
            e.dedup();
            e.iter().map(|(a, b)| format!("{a}>{b}")).collect::<Vec<_>>().join(",")
        };
        p("tred", back(&red));
        p("tclo", back(&clo));
    }
}

fn fam(family: &str, n: usize) -> (usize, Vec<(usize, usize, i64)>) {
    let mut e = Vec::new();
    match family {
        "chain" | "cycle" => {
            for i in 0..n.saturating_sub(1) {
                e.push((i, i + 1, (i * 7 % 10 + 1) as i64));
            }
            if family == "cycle" && n > 1 {
                e.push((n - 1, 0, 1));
            }
        }
        "star" => {
            for i in 1..n {
                e.push((0, i, (i % 10 + 1) as i64));
            }
        }
        "rand" => {
            let mut r = Rng(0x5eed5eed5eed5eed);
            for i in 0..n.saturating_sub(1) {
                e.push((i, i + 1, (r.below(1000) + 1) as i64));
            }
            for _ in 0..3 * n {
                let u = r.below(n as u64) as usize;
                let v = r.below(n as u64) as usize;
                e.push((u, v, (r.below(1000) + 1) as i64));
            }
        }
        "dense" => {
            for u in 0..n {
                for v in 0..n {
                    if u != v && (u * 31 + v) % 3 == 0 {
                        e.push((u, v, ((u * 7 + v * 13) % 100 + 1) as i64));
                    }
                }
            }
        }
        "layers" => {
            let mut r = Rng(0x0d1c0d1c0d1c0d1c);
            let w = 10;
            let layers = (n - 2) / w;
            for j in 0..w {
                e.push((0, 1 + j, (r.below(1000000000) + 1) as i64));
            }
            for l in 0..layers - 1 {
                for a in 0..w {
                    for b in 0..w {
                        e.push((1 + l * w + a, 1 + (l + 1) * w + b, (r.below(1000000000) + 1) as i64));
                    }
                }
            }
            let sink = 1 + layers * w;
            for z in 0..w {
                e.push((1 + (layers - 1) * w + z, sink, (r.below(1000000000) + 1) as i64));
            }
            return (layers * w + 2, e);
        }
        _ => panic!("unknown family"),
    }
    (n, e)
}

fn stress(family: &str, n_in: usize, algo: &str) {
    let (n, edges) = fam(family, n_in);
    let mut d: DiGraph<(), i64> = DiGraph::with_capacity(n, edges.len());
    let mut u: UnGraph<(), i64> = UnGraph::with_capacity(n, edges.len());
    for _ in 0..n {
        d.add_node(());
        u.add_node(());
    }
    for &(a, b, w) in &edges {
        d.add_edge(NodeIndex::new(a), NodeIndex::new(b), w);
        u.add_edge(NodeIndex::new(a), NodeIndex::new(b), w);
    }
    let head = format!("family={family} n={n} m={}", edges.len());
    let src = NodeIndex::new(0);
    match algo {
        "dij" => {
            let m = dijkstra(&d, src, None, |e| *e.weight());
            let s: i64 = m.values().sum();
            println!("{head} algo=dij reach={} sum={s}", m.len());
        }
        "bf" => {
            let mut fd: DiGraph<(), f64> = DiGraph::with_capacity(n, edges.len());
            for _ in 0..n {
                fd.add_node(());
            }
            for &(a, b, w) in &edges {
                fd.add_edge(NodeIndex::new(a), NodeIndex::new(b), w as f64);
            }
            match bellman_ford(&fd, src) {
                Ok(p) => {
                    let f: Vec<f64> = p.distances.into_iter().filter(|x| x.is_finite()).collect();
                    println!("{head} algo=bf reach={} sum={}", f.len(), f.iter().map(|x| *x as i64).sum::<i64>());
                }
                Err(_) => println!("{head} algo=bf negcycle"),
            }
        }
        "astar" => match astar(&d, src, |x| x.index() == n - 1, |e| *e.weight(), |_| 0) {
            Some((c, p)) => println!("{head} algo=astar cost={c} len={}", p.len()),
            None => println!("{head} algo=astar none"),
        },
        "tarjan" | "kosaraju" => {
            let s = if algo == "tarjan" { tarjan_scc(&d) } else { kosaraju_scc(&d) };
            let big = s.iter().map(|c| c.len()).max().unwrap_or(0);
            println!("{head} algo=scc count={} largest={big}", s.len());
        }
        "topo" => match toposort(&d, None) {
            Ok(o) => println!("{head} algo=topo len={}", o.len()),
            Err(_) => println!("{head} algo=topo cycle"),
        },
        "dom" => {
            let dm = dominators::simple_fast(&d, src);
            let mut s: i64 = 0;
            let mut c = 0;
            for v in 0..n {
                if v == 0 {
                    c += 1;
                } else if let Some(x) = dm.immediate_dominator(NodeIndex::new(v)) {
                    s += x.index() as i64;
                    c += 1;
                }
            }
            println!("{head} algo=dom reach={c} sum_idom={s}");
        }
        "dinic" => {
            let mut fg: DiGraph<(), u64> = DiGraph::with_capacity(n, edges.len());
            for _ in 0..n {
                fg.add_node(());
            }
            for &(a, b, w) in &edges {
                fg.add_edge(NodeIndex::new(a), NodeIndex::new(b), w as u64);
            }
            let (f, _) = dinics(&fg, src, NodeIndex::new(n - 1));
            println!("{head} algo=dinic flow={f}");
        }
        "floyd" => match floyd_warshall(&d, |e| *e.weight()) {
            Ok(m) => {
                let mut s: i64 = 0;
                let mut c = 0;
                for (_, &v) in m.iter() {
                    if v != i64::MAX {
                        s = s.wrapping_add(v);
                        c += 1;
                    }
                }
                println!("{head} algo=floyd reach={c} sum={s}");
            }
            Err(_) => println!("{head} algo=floyd negcycle"),
        },
        "kruskal" | "prim" => {
            let mut s: i64 = 0;
            let mut c = 0;
            let it: Box<dyn Iterator<Item = Element<(), i64>>> =
                if algo == "kruskal" { Box::new(min_spanning_tree(&u)) } else { Box::new(min_spanning_tree_prim(&u)) };
            for e in it {
                if let Element::Edge { weight, .. } = e {
                    s += weight;
                    c += 1;
                }
            }
            println!("{head} algo=mst total={s} edges={c}");
        }
        "bridges" => println!("{head} algo=bridges count={}", bridges(&u).count()),
        "ap" => println!(
            "{head} algo=ap count={}",
            petgraph::algo::articulation_points::articulation_points(&u).len()
        ),
        "tred" => {
            let mut dd: DiGraph<(), ()> = DiGraph::with_capacity(n, edges.len());
            for _ in 0..n {
                dd.add_node(());
            }
            for &(a, b, _) in &edges {
                dd.add_edge(NodeIndex::new(a), NodeIndex::new(b), ());
            }
            match toposort(&dd, None) {
                Ok(t) => {
                    let (l, _) = dag_to_toposorted_adjacency_list::<_, u32>(&dd, &t);
                    let (red, _) = dag_transitive_reduction_closure(&l);
                    let mut c = 0;
                    for a in 0..red.node_count() as u32 {
                        c += red.neighbors(a).count();
                    }
                    println!("{head} algo=tred edges={c}");
                }
                Err(_) => println!("{head} algo=tred cycle"),
            }
        }
        "removenodes" => {
            let target = n / 2;
            for k in 0..target {
                let cnt = d.node_count();
                d.remove_node(NodeIndex::new(k * 7919 % cnt));
            }
            let h: i64 = d.edge_references().map(|e| (e.source().index() * 31 + e.target().index()) as i64).sum();
            println!("{head} algo=removenodes nodes={} edges={} h={h}", d.node_count(), d.edge_count());
        }
        "none" => println!("{head} algo=none"),
        _ => panic!("unknown algo"),
    }
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() < 4 || (a[1] != "fuzz" && a[1] != "dump" && a[1] != "stress") {
        eprintln!("usage: graph_oracle fuzz <seed> <cases>");
        std::process::exit(2);
    }
    if a.len() >= 5 && a[1] == "stress" {
        stress(&a[2], a[3].parse().unwrap(), &a[4]);
        return;
    }
    if a.len() >= 4 && a[1] == "dump" {
        // dump <seed> <case>: print the three generated graphs (directed, undirected, dag source)
        let (seed, case): (u64, u64) = (a[2].parse().unwrap(), a[3].parse().unwrap());
        let mut r = Rng(seed ^ (case + 1).wrapping_mul(0x9E3779B97F4A7C15));
        r.next();
        r.next();
        for name in ["digraph", "ungraph", "dag_src"] {
            let g = gen(&mut r);
            let es: Vec<String> = g.edges.iter().map(|(u, v, w)| format!("({u},{v},{w})")).collect();
            println!("{name} n={} wkind={} edges=[{}]", g.n, g.wkind, es.join(", "));
        }
        return;
    }
    let seed: u64 = a[2].parse().unwrap();
    let cases: u64 = a[3].parse().unwrap();
    for c in 0..cases {
        run_case(seed, c);
    }
}
