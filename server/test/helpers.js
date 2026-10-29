// Ayudas compartidas por las pruebas y por scripts/demo.js: un mundo con reloj propio, pedidos
// firmados como Telegram y partidas de prueba que el servidor acepta.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import worker from "../src/index.js";
import { signInitData } from "../src/telegram.js";
import { Board } from "../src/rules.js";
import { makeD1 } from "./d1.js";

export const BOT = "123456:TEST-TOKEN-NOT-REAL";
export const config = JSON.parse(readFileSync(new URL("../../data/config.json", import.meta.url), "utf8"));
export const day = (d, h = 15) => Date.parse(`${d}T${String(h).padStart(2, "0")}:00:00Z`);

export function makeWorld(eventsOn) {
  let now = day("2026-10-20");
  const env = {
    DB: makeD1(), BOT_TOKEN: BOT, DAILY_SECRET: "test-daily-secret", STATS_TOKEN: "test-stats-token",
    ALLOWED_ORIGIN: "https://x.test", EVENTS_ENABLED: eventsOn ? "true" : "false", clock: () => now,
  };
  return { env, at: (ms) => (now = ms), tick: (ms) => (now += ms), now: () => now };
}

export async function call(w, method, path, user, body, headers = {}) {
  const h = { ...headers };
  if (user) {
    h.Authorization = "tma " + (await signInitData({ auth_date: String(Math.floor(w.now() / 1000)), user: JSON.stringify(user) }, BOT));
  }
  const res = await worker.fetch(new Request("https://api.test" + path, { method, headers: h, body: body ? JSON.stringify(body) : undefined }), w.env);
  const text = await res.text();
  let parsed = text;
  try { parsed = JSON.parse(text); } catch { /* es CSV */ }
  return { status: res.status, body: parsed, text };
}

export function playFor(seed, count) {
  const b = new Board(config, seed);
  const moves = [];
  for (let k = 0; k < count; k++) {
    const ch = b.findAnyChain();
    moves.push({ cells: ch, t: 1200 * (k + 1) });
    b.clearChain(ch);
  }
  return moves;
}

// Un día de un jugador: abre, empieza el Daily y lo termina.
export async function playDay(w, user, when, chains = 5) {
  w.at(when);
  await call(w, "POST", "/session", user);
  const st = await call(w, "POST", "/daily/start", user);
  assert.equal(st.status, 200, JSON.stringify(st.body));
  w.tick(61000);
  const r = await call(w, "POST", "/run", user, { run_id: st.body.run_id, moves: playFor(st.body.seed, chains), final: true });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return st.body;
}

export const person = (i) => ({ id: 2000 + i, first_name: `Jugador${i}`, last_name: "Prueba", username: `user${i}` });
