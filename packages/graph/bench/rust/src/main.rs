use petgraph::algo::{dijkstra, dominators, min_spanning_tree, tarjan_scc, toposort};
use petgraph::data::Element;
use petgraph::graph::{DiGraph, NodeIndex, UnGraph};
use std::env;

#[inline(always)]
fn next_u64(state: u64) -> u64 {
    state
        .wrapping_mul(6364136223846793005u64)
        .wrapping_add(1442695040888963407u64)
}

fn bench_dijkstra() {
    let n: usize = 50_000;
    let m: usize = 250_000;
    let mut g: DiGraph<(), i64> = DiGraph::with_capacity(n, m);
    for _ in 0..n {
        g.add_node(());
    }
    let mut state: u64 = 0x123456789abcdef0;
    for j in 0..(n - 1) {
        state = next_u64(state);
        let w = ((state >> 32) % 1000 + 1) as i64;
        g.add_edge(NodeIndex::new(j), NodeIndex::new(j + 1), w);
    }
    let rem = m - (n - 1);
    for _ in 0..rem {
        state = next_u64(state);
        let u = ((state >> 32) % (n as u64)) as usize;
        state = next_u64(state);
        let v = ((state >> 32) % (n as u64)) as usize;
        state = next_u64(state);
        let w = ((state >> 32) % 1000 + 1) as i64;
        g.add_edge(NodeIndex::new(u), NodeIndex::new(v), w);
    }

    let rounds = 3;
    let mut sum_dist: i64 = 0;
    let mut xor_dist: i64 = 0;
    let mut reach_cnt: usize = 0;
    for r in 0..rounds {
        let map = dijkstra(&g, NodeIndex::new(0), None, |e| *e.weight());
        if r == rounds - 1 {
            for v in 0..n {
                if let Some(&d) = map.get(&NodeIndex::new(v)) {
                    reach_cnt += 1;
                    sum_dist += d;
                    xor_dist ^= d;
                }
            }
        }
    }
    println!("mode=dijkstra");
    println!("nodes={n}");
    println!("edges={m}");
    println!("reachable={reach_cnt}");
    println!("sum_dist={sum_dist}");
    println!("xor_dist={xor_dist}");
}

fn bench_scc_topo() {
    let n: usize = 100_000;
    let m: usize = 400_000;

    let mut g_scc: DiGraph<(), ()> = DiGraph::with_capacity(n, m);
    for _ in 0..n {
        g_scc.add_node(());
    }
    let mut edges_scc = Vec::with_capacity(m);
    let mut state: u64 = 0xfeedfacecafebeef;
    for _ in 0..m {
        state = next_u64(state);
        let u = ((state >> 32) % (n as u64)) as usize;
        state = next_u64(state);
        let offset = ((state >> 32) % 32) as isize - 16;
        let v = ((u as isize + offset + n as isize) as usize) % n;
        g_scc.add_edge(NodeIndex::new(u), NodeIndex::new(v), ());
        edges_scc.push((u, v));
    }

    let mut g_dag: DiGraph<(), ()> = DiGraph::with_capacity(n, m);
    for _ in 0..n {
        g_dag.add_node(());
    }
    let mut edges_dag = Vec::with_capacity(m);
    let mut state2: u64 = 0xabcdef0123456789;
    for _ in 0..m {
        state2 = next_u64(state2);
        let u = ((state2 >> 32) % ((n - 1) as u64)) as usize;
        state2 = next_u64(state2);
        let max_span = n - 1 - u;
        let span_lim = if max_span < 64 { max_span } else { 64 };
        let delta = ((state2 >> 32) % (span_lim as u64)) as usize + 1;
        let v = u + delta;
        g_dag.add_edge(NodeIndex::new(u), NodeIndex::new(v), ());
        edges_dag.push((u, v));
    }

    let sccs = tarjan_scc(&g_scc);
    let order = toposort(&g_dag, None).expect("dag must be acyclic");

    let mut max_scc: usize = 0;
    let mut sum_sq: i64 = 0;
    let mut comp = vec![-1isize; n];
    for (ci, scc) in sccs.iter().enumerate() {
        let sz = scc.len();
        if sz > max_scc {
            max_scc = sz;
        }
        let sz64 = sz as i64;
        sum_sq += sz64 * sz64;
        for &node in scc {
            comp[node.index()] = ci as isize;
        }
    }

    let mut rev_topo_ok = 1;
    for &(u, v) in &edges_scc {
        if comp[u] < comp[v] {
            rev_topo_ok = 0;
            break;
        }
    }

    let mut pos = vec![0usize; n];
    for (pi, &node) in order.iter().enumerate() {
        pos[node.index()] = pi;
    }
    let mut topo_ok = 1;
    for &(u, v) in &edges_dag {
        if pos[u] >= pos[v] {
            topo_ok = 0;
            break;
        }
    }

    println!("mode=scc_topo");
    println!("nodes={n}");
    println!("edges={m}");
    println!("scc_count={}", sccs.len());
    println!("max_scc={max_scc}");
    println!("sum_sq_scc={sum_sq}");
    println!("rev_topo_ok={rev_topo_ok}");
    println!("topo_len={}", order.len());
    println!("topo_ok={topo_ok}");
}

fn bench_kruskal() {
    let n: usize = 50_000;
    let m: usize = 200_000;
    let mut g: UnGraph<(), i64> = UnGraph::with_capacity(n, m);
    for _ in 0..n {
        g.add_node(());
    }
    let mut state: u64 = 0x0123456789abcdef;
    for j in 0..(n - 1) {
        state = next_u64(state);
        let w = ((state >> 32) % 1_000_000 + 1) as i64;
        g.add_edge(NodeIndex::new(j), NodeIndex::new(j + 1), w);
    }
    let rem = m - (n - 1);
    for _ in 0..rem {
        state = next_u64(state);
        let u = ((state >> 32) % (n as u64)) as usize;
        state = next_u64(state);
        let v = ((state >> 32) % (n as u64)) as usize;
        state = next_u64(state);
        let w = ((state >> 32) % 1_000_000 + 1) as i64;
        g.add_edge(NodeIndex::new(u), NodeIndex::new(v), w);
    }

    let mut mst_edges: usize = 0;
    let mut total_weight: i64 = 0;
    for elem in min_spanning_tree(&g) {
        if let Element::Edge { weight, .. } = elem {
            mst_edges += 1;
            total_weight += weight;
        }
    }
    println!("mode=kruskal");
    println!("nodes={n}");
    println!("edges={m}");
    println!("mst_edges={mst_edges}");
    println!("total_weight={total_weight}");
}

fn bench_dominators() {
    let n: usize = 20_000;
    let m: usize = 60_000;
    let mut g: DiGraph<(), ()> = DiGraph::with_capacity(n, m);
    for _ in 0..n {
        g.add_node(());
    }
    for j in 0..(n - 1) {
        g.add_edge(NodeIndex::new(j), NodeIndex::new(j + 1), ());
    }
    let mut state: u64 = 0xdeadbeef1337c0de;
    let rem = m - (n - 1);
    for _ in 0..rem {
        state = next_u64(state);
        let u = ((state >> 32) % ((n - 2) as u64)) as usize + 1;
        state = next_u64(state);
        let r = (state >> 32) % 10;
        let v = if r < 7 {
            let step = ((state >> 16) % 16) as usize + 1;
            let cand = u + step;
            if cand < n { cand } else { n - 1 }
        } else {
            let step = ((state >> 16) % 8) as usize + 1;
            if u > step { u - step } else { 1 }
        };
        g.add_edge(NodeIndex::new(u), NodeIndex::new(v), ());
    }

    let rounds = 5;
    let mut dom_cnt: usize = 0;
    let mut sum_idom: i64 = 0;
    let mut xor_idom: i64 = 0;
    for r in 0..rounds {
        let dom = dominators::simple_fast(&g, NodeIndex::new(0));
        if r == rounds - 1 {
            for v in 1..n {
                if let Some(p) = dom.immediate_dominator(NodeIndex::new(v)) {
                    dom_cnt += 1;
                    let pi = p.index() as i64;
                    sum_idom += pi;
                    xor_idom ^= (v as i64) * 31 + pi;
                }
            }
        }
    }
    println!("mode=dominators");
    println!("nodes={n}");
    println!("edges={m}");
    println!("dominated_count={dom_cnt}");
    println!("sum_idom={sum_idom}");
    println!("xor_idom={xor_idom}");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: graph_bench_rust <w1_dijkstra|w2_scc_topo|w3_kruskal|w4_dominators>");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "w1_dijkstra" => bench_dijkstra(),
        "w2_scc_topo" => bench_scc_topo(),
        "w3_kruskal" => bench_kruskal(),
        "w4_dominators" => bench_dominators(),
        other => {
            eprintln!("unknown mode: {other}");
            std::process::exit(1);
        }
    }
}
