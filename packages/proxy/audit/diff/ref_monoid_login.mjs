// Reference oracle: parseProxyUrl / redactProxyUrl ported verbatim (types stripped) from
// AFK-surf/monoid-login@886d08e5 src/proxy-bridge.ts:30-118, the code packages/proxy replaces.
// Input: one hex-encoded URL per line. Output format matches `probe urls`.
import { readFileSync } from "node:fs";
import { isIP } from "node:net";

const DEFAULT_PORTS = { http: 80, https: 443, socks5: 1080, socks5h: 1080, ssh: 22 };

function withScheme(raw) {
  const trimmed = raw.trim();
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
}

function safeDecode(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

export function parseProxyUrl(raw) {
  if (typeof raw !== "string" || raw.trim() === "") {
    throw new Error("代理地址为空");
  }
  let url;
  try {
    url = new URL(withScheme(raw));
  } catch {
    throw new Error(`代理地址无法解析：${redactProxyUrl(raw)}`);
  }
  const scheme = url.protocol.replace(/:$/, "").toLowerCase();
  if (scheme !== "http" && scheme !== "https" && scheme !== "socks5" && scheme !== "socks5h" && scheme !== "ssh") {
    throw new Error(`不支持的代理协议：${scheme}（仅支持 http / https / socks5 / socks5h / ssh）`);
  }
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (!host) throw new Error(`代理地址缺少主机：${redactProxyUrl(raw)}`);
  const port = url.port ? Number(url.port) : DEFAULT_PORTS[scheme];
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`代理端口无效：${redactProxyUrl(raw)}`);
  }
  if (scheme === "ssh") {
    if (url.password) throw new Error("ssh:// 出口不支持在地址里写密码，请改用密钥（?identity=/path/to/key）或 ssh-agent");
    const identity = url.searchParams.get("identity");
    return {
      scheme, host, port,
      username: url.username ? safeDecode(url.username) : null,
      password: null,
      identity: identity && identity.trim() !== "" ? identity.trim() : null,
    };
  }
  return {
    scheme, host, port,
    username: url.username ? safeDecode(url.username) : null,
    password: url.password ? safeDecode(url.password) : url.username ? "" : null,
  };
}

function formatHost(host) {
  return isIP(host) === 6 ? `[${host}]` : host;
}

export function redactProxyUrl(raw) {
  if (typeof raw !== "string" || raw.trim() === "") return "";
  try {
    const p = parseProxyUrl(raw);
    if (p.scheme === "ssh") {
      const user = p.username !== null ? `${encodeURIComponent(p.username)}@` : "";
      return `ssh://${user}${formatHost(p.host)}:${p.port}`;
    }
    const auth = p.username !== null ? "***@" : "";
    return `${p.scheme}://${auth}${formatHost(p.host)}:${p.port}`;
  } catch {
    const stripped = raw.trim().replace(/^([a-z][a-z0-9+.-]*:\/\/)?[^@/]*@/i, (_m, s) => `${s ?? ""}***@`);
    return stripped.includes("@") ? stripped : stripped.replace(/[^A-Za-z0-9.:/\[\]*@-]/g, "");
  }
}

// Same escaping as probe's `esc`: bytes < 0x20, >= 0x7f and '\' become \xNN.
function esc(s) {
  let out = "";
  for (const c of Buffer.from(s, "utf8")) {
    out += c < 32 || c >= 127 || c === 92 ? "\\x" + c.toString(16).padStart(2, "0") : String.fromCharCode(c);
  }
  return out;
}

const lines = readFileSync(process.argv[2], "utf8").split("\n");
if (lines[lines.length - 1] === "") lines.pop();
let out = "";
for (const h of lines) {
  const raw = Buffer.from(h, "hex").toString("utf8");
  try {
    const p = parseProxyUrl(raw);
    const u = p.username === null ? "u-" : "u=" + esc(p.username);
    const pw = p.password === null ? "p-" : "p=" + esc(p.password);
    out += `ok\t${esc(p.host.toLowerCase())}\t${p.port}\t${u}\t${pw}\t${esc(redactProxyUrl(raw))}\n`;
  } catch (e) {
    out += `err\t\t\t\t\t${esc(e.message)}\n`;
  }
}
process.stdout.write(out);
