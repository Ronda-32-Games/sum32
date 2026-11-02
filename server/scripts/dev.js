// Base local del servidor (TASK-059): el mismo Worker con una base SQLite en un archivo y
// jugadores de mentira, para probar el Daily sin las claves de Cloudflare ni Telegram.
//
//   cd server && node scripts/dev.js            # http://localhost:8787, base en .dev/sum32.db
//   node scripts/dev.js --fresh                 # empieza con la base vacía
//   node scripts/dev.js --port 8788 --db /tmp/x.db
//
// Después, con la build web servida en localhost: index.html?api=http://localhost:8787
// (y &user=2, &user=3... para jugar como otro). Rutas extra solo de acá:
//   GET  /dev/login?user=N   initData firmado como Telegram para el jugador N
//   POST /dev/clock          {"plus_ms": 86400000} adelanta el reloj (otro día, otros intentos)
import http from "node:http";
import { mkdirSync, rmSync } from "node:fs";
import { dirname } from "node:path";
import worker from "../src/index.js";
import { signInitData } from "../src/telegram.js";
import { makeD1 } from "../test/d1.js";

const arg = (name, def) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : def;
};
const PORT = Number(arg("--port", 8787));
const DB = arg("--db", new URL("../.dev/sum32.db", import.meta.url).pathname);
const BOT = "000000:DEV-ONLY-NOT-A-REAL-TOKEN";
const NAMES = ["Nacho", "Ana", "Lucas", "Sofi", "Tomi", "Vera", "Nahir", "Max"];

if (process.argv.includes("--fresh")) rmSync(DB, { force: true });
mkdirSync(dirname(DB), { recursive: true });

let offset = 0;
const env = {
  DB: makeD1(DB),
  BOT_TOKEN: BOT,
  DAILY_SECRET: "dev-daily-secret",
  STATS_TOKEN: "dev-stats",
  ALLOWED_ORIGIN: "", // se completa con el origen que pida (solo localhost)
  EVENTS_ENABLED: "true",
  clock: () => Date.now() + offset,
};

const local = (o) => /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o || "");

async function devRoute(url, req, body) {
  if (url.pathname === "/dev/login") {
    const n = Math.max(1, Number(url.searchParams.get("user")) || 1);
    const user = { id: 1000 + n, first_name: NAMES[(n - 1) % NAMES.length] + (n > NAMES.length ? ` ${n}` : "") };
    const initData = await signInitData({ auth_date: String(Math.floor(env.clock() / 1000)), user: JSON.stringify(user) }, BOT);
    return { init_data: initData, user };
  }
  if (url.pathname === "/dev/clock" && req.method === "POST") {
    offset += Number(JSON.parse(body || "{}").plus_ms) || 0;
    return { now: new Date(env.clock()).toISOString() };
  }
  return null;
}

http.createServer(async (req, res) => {
  const origin = req.headers.origin || "";
  if (local(origin)) env.ALLOWED_ORIGIN = origin;
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks).toString("utf8");
  const url = new URL(req.url, `http://localhost:${PORT}`);
  try {
    if (url.pathname.startsWith("/dev/")) {
      const out = await devRoute(url, req, body);
      res.writeHead(out ? 200 : 404, { "Content-Type": "application/json", ...(local(origin) ? { "Access-Control-Allow-Origin": origin } : {}) });
      res.end(JSON.stringify(out || { error: "not_found" }));
      return;
    }
    const r = await worker.fetch(new Request(url, { method: req.method, headers: req.headers, body: ["GET", "HEAD"].includes(req.method) ? undefined : body }), env);
    res.writeHead(r.status, Object.fromEntries(r.headers));
    res.end(await r.text());
    console.log(req.method, url.pathname, r.status);
  } catch (e) {
    console.error(e);
    res.writeHead(500);
    res.end();
  }
}).listen(PORT, () => console.log(`Sum 32, base local: http://localhost:${PORT}  (base ${DB})`));
