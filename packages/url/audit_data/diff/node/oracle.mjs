// Oracle for the data: URL differential: Node.js fetch() (undici), which runs the
// WHATWG URL parser and then the Fetch Standard §6 "data: URL processor" and
// WHATWG Infra forgiving-base64 decode. Same line protocol as ../pion/src/main.pion.
import { createInterface } from "node:readline";

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
const out = [];
for await (const line of rl) {
  if (!line) continue;
  const input = Buffer.from(line, "hex").toString("utf8");
  try {
    const res = await fetch(input);
    const ct = res.headers.get("content-type") ?? "";
    const body = Buffer.from(await res.arrayBuffer());
    out.push(`OK\t${Buffer.from(ct, "latin1").toString("hex")}\t${body.toString("hex")}`);
  } catch (e) {
    out.push("ERR\tnetwork error");
  }
}
process.stdout.write(out.join("\n") + "\n");
