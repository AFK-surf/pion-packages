// Head-to-head Node.js baseline for packages/effect benchmarks.

class BoundedQueue {
  constructor(cap) {
    this.cap = cap;
    this.buf = new Array(cap);
    this.head = 0;
    this.len = 0;
    this.putters = [];
    this.takers = [];
    this.shut = false;
  }
  async offer(x) {
    while (this.len === this.cap) {
      await new Promise((r) => this.putters.push(r));
    }
    this.buf[(this.head + this.len) % this.cap] = x;
    this.len++;
    if (this.takers.length > 0) {
      const r = this.takers.shift();
      r();
    }
  }
  async take() {
    while (this.len === 0) {
      if (this.shut) return null;
      await new Promise((r) => this.takers.push(r));
    }
    const v = this.buf[this.head];
    this.head = (this.head + 1) % this.cap;
    this.len--;
    if (this.putters.length > 0) {
      const r = this.putters.shift();
      r();
    }
    return v;
  }
  shutdown() {
    this.shut = true;
    while (this.takers.length > 0) this.takers.shift()();
  }
}

async function benchQueue() {
  const n = 50000;
  const q = new BoundedQueue(16);
  const prod = (async () => {
    for (let i = 0; i < n; i++) {
      await q.offer(i);
    }
    q.shutdown();
  })();
  let acc = 0;
  let cnt = 0;
  while (true) {
    const v = await q.take();
    if (v === null) break;
    acc = (Math.imul(acc, 31) + v) & 0x7fffffff;
    cnt++;
  }
  await prod;
  process.stdout.write(`mode=queue\nops=${cnt}\nchecksum=${acc}\n`);
}

function heapBefore(a, b) {
  return a.at < b.at || (a.at === b.at && a.seq < b.seq);
}

function heapPush(h, item) {
  h.push(item);
  let i = h.length - 1;
  while (i > 0) {
    const p = (i - 1) >> 1;
    if (heapBefore(h[i], h[p])) {
      const tmp = h[i];
      h[i] = h[p];
      h[p] = tmp;
      i = p;
    } else {
      break;
    }
  }
}

function heapPop(h) {
  const top = h[0];
  const last = h.pop();
  const m = h.length;
  if (m > 0) {
    h[0] = last;
    let i = 0;
    while (true) {
      const l = (i << 1) + 1;
      const r = l + 1;
      let s = i;
      if (l < m && heapBefore(h[l], h[s])) s = l;
      if (r < m && heapBefore(h[r], h[s])) s = r;
      if (s === i) break;
      const tmp = h[i];
      h[i] = h[s];
      h[s] = tmp;
      i = s;
    }
  }
  return top;
}

function benchTimers() {
  const n = 20000;
  const h = [];
  for (let i = 0; i < n; i++) {
    const delay = ((i * 7919) % 500) + 1;
    heapPush(h, { at: delay, seq: i + 1, idx: i });
  }
  let acc = 0;
  let fired = 0;
  while (h.length > 0 && h[0].at <= 505) {
    const t = heapPop(h);
    acc = (Math.imul(acc, 31) + Math.imul(t.at, 131) + t.idx) & 0x7fffffff;
    fired++;
  }
  process.stdout.write(`mode=timers\nops=${fired}\nnow=505\nchecksum=${acc}\n`);
}

async function benchFanout() {
  const batches = 2500;
  let acc = 0;
  let total = 0;
  for (let b = 0; b < batches; b++) {
    const base = b * 4;
    const xs = await Promise.all([
      Promise.resolve().then(() => base + 1),
      Promise.resolve().then(() => base + 2),
      Promise.resolve().then(() => base + 3),
      Promise.resolve().then(() => base + 4),
    ]);
    const s = xs[0] + xs[1] + xs[2] + xs[3];
    acc = (Math.imul(acc, 31) + s) & 0x7fffffff;
    total += xs.length;
  }
  process.stdout.write(`mode=fanout\nops=${total}\nchecksum=${acc}\n`);
}

const mode = process.argv[2];
if (mode === "queue") {
  await benchQueue();
} else if (mode === "timers") {
  benchTimers();
} else if (mode === "fanout") {
  await benchFanout();
} else {
  process.stderr.write(`usage: node bench.mjs <queue|timers|fanout>\n`);
  process.exit(1);
}
