// Pruebas del servidor de punta a punta: firma de Telegram, Daily, intentos, partida y ranking.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker, { dayOf } from "../src/index.js";
import { signInitData, dailySeed } from "../src/telegram.js";
import { makeD1 } from "./d1.js";

const BOT = "123456:TEST-TOKEN-NOT-REAL";
const vectors = JSON.parse(readFileSync(new URL("../../tests/round_vectors.json", import.meta.url), "utf8"));
const config = JSON.parse(readFileSync(new URL("../../data/config.json", import.meta.url), "utf8"));
const ORIGIN = "https://ronda-32-games.github.io";
const T0 = Date.parse("2026-10-29T15:00:00Z");

function setup() {
  let now = T0;
  const env = { DB: makeD1(), BOT_TOKEN: BOT, DAILY_SECRET: "test-daily-secret", ALLOWED_ORIGIN: ORIGIN, clock: () => now };
  return { env, tick: (ms) => (now += ms), at: (ms) => (now = ms), now: () => now };
}

async function initData(user, now, extra = {}) {
  return signInitData({ auth_date: String(Math.floor(now / 1000)), user: JSON.stringify(user), ...extra }, BOT);
}

async function call(ctx, method, path, user, body, opts = {}) {
  const headers = { Origin: ORIGIN };
  if (user) headers.Authorization = "tma " + (opts.raw ?? (await initData(user, ctx.now())));
  const req = new Request("https://api.test" + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const res = await worker.fetch(req, ctx.env);
  return { status: res.status, body: await res.json(), headers: res.headers };
}

const ana = { id: 1001, first_name: "Ana", last_name: "Pérez", username: "ana" };
const beto = { id: 1002, first_name: "Beto" };

// Una partida real para la semilla del día: el juego en Godot la encontraría igual.
import { Board } from "../src/rules.js";
function playFor(seed, count, gap = 1200) {
  const b = new Board(config, seed);
  const moves = [];
  let t = 0;
  for (let k = 0; k < count; k++) {
    t += gap;
    const ch = b.findAnyChain();
    moves.push({ cells: ch, t });
    b.clearChain(ch);
  }
  return moves;
}

test("firma de Telegram: sin firma, firma mala o vieja no entra", async () => {
  const ctx = setup();
  assert.equal((await call(ctx, "GET", "/health")).status, 200);
  assert.equal((await call(ctx, "GET", "/daily")).body.error, "no_auth");
  const good = await initData(ana, ctx.now());
  const forged = good.replace("Ana", "Eve");
  assert.equal((await call(ctx, "GET", "/daily", ana, null, { raw: forged })).body.error, "bad_auth");
  const old = await initData(ana, ctx.now() - 2 * 86400000);
  assert.equal((await call(ctx, "GET", "/daily", ana, null, { raw: old })).body.error, "bad_auth");
  const r = await call(ctx, "POST", "/session", ana);
  assert.equal(r.status, 200);
  assert.equal(r.body.user.name, "Ana P.");
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), ORIGIN);
});

test("Daily: la semilla llega recién al gastar el intento, y hay tope", async () => {
  const ctx = setup();
  const s = await call(ctx, "POST", "/session", ana);
  assert.equal(s.body.daily.attempts_left, config.daily_free_attempts);
  assert.equal(JSON.stringify(s.body).includes("seed"), false, "/session no muestra la grilla");
  const seeds = new Set();
  for (let k = 0; k < config.daily_free_attempts; k++) {
    const st = await call(ctx, "POST", "/daily/start", ana);
    assert.equal(st.status, 200);
    seeds.add(st.body.seed);
  }
  assert.equal(seeds.size, 1, "misma grilla en todos los intentos del día");
  assert.equal(seeds.has(await dailySeed("test-daily-secret", dayOf(T0))), true);
  const no = await call(ctx, "POST", "/daily/start", ana);
  assert.equal(no.status, 403);
  assert.equal(no.body.error, "no_attempts");
  // Al otro día hay intentos y otra grilla.
  ctx.at(Date.parse("2026-10-30T00:00:01Z"));
  const next = await call(ctx, "POST", "/daily/start", ana);
  assert.equal(next.status, 200);
  assert.equal(seeds.has(next.body.seed), false);
});

test("partida verificada: puntaje del servidor, ranking y mejor del día", async () => {
  const ctx = setup();
  const st = await call(ctx, "POST", "/daily/start", ana);
  const moves = playFor(st.body.seed, 20);
  ctx.tick(30000);
  const part = await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves: moves.slice(0, 10) });
  assert.equal(part.status, 200, JSON.stringify(part.body));
  assert.equal(part.body.status, "open");
  ctx.tick(31000);
  const fin = await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves, final: true });
  assert.equal(fin.status, 200, JSON.stringify(fin.body));
  assert.equal(fin.body.chains, 20);
  assert.equal(fin.body.rank, 1);
  const again = await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves, final: true });
  assert.equal(again.body.error, "run_closed", "una partida cerrada no se vuelve a mandar");
  // Beto hace menos; después Ana juega peor y su mejor del día no baja.
  const sb = await call(ctx, "POST", "/daily/start", beto);
  ctx.tick(61000);
  await call(ctx, "POST", "/run", beto, { run_id: sb.body.run_id, moves: playFor(sb.body.seed, 5), final: true });
  const s2 = await call(ctx, "POST", "/daily/start", ana);
  ctx.tick(61000);
  const worse = await call(ctx, "POST", "/run", ana, { run_id: s2.body.run_id, moves: playFor(s2.body.seed, 3), final: true });
  assert.equal(worse.body.day_best, fin.body.score);
  const lb = await call(ctx, "GET", "/leaderboard", beto);
  assert.equal(lb.body.players, 2);
  assert.deepEqual(lb.body.top.map((r) => r.name), ["Ana P.", "Beto"]);
  assert.equal(lb.body.top[0].score, fin.body.score);
  assert.deepEqual(lb.body.me, { rank: 2, score: lb.body.top[1].score });
});

test("partida abandonada: gasta el intento y queda con lo que alcanzó a mandar", async () => {
  const ctx = setup();
  const st = await call(ctx, "POST", "/daily/start", ana);
  const moves = playFor(st.body.seed, 6);
  ctx.tick(20000);
  const part = await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves });
  await call(ctx, "POST", "/daily/start", ana); // vuelve a abrir: la anterior se cierra
  const late = await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves, final: true });
  assert.equal(late.body.error, "run_closed");
  const d = await call(ctx, "GET", "/daily", ana);
  assert.equal(d.body.best.score, part.body.score);
  assert.equal(d.body.attempts_used, 2);
});

test("trampas: jugadas cambiadas, imposibles, más rápidas que el reloj o de otro", async () => {
  const ctx = setup();
  let st = await call(ctx, "POST", "/daily/start", ana);
  let moves = playFor(st.body.seed, 10);
  ctx.tick(60000);
  await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves: moves.slice(0, 5) });
  const swapped = [...moves.slice(0, 4), moves[6], ...moves.slice(5)];
  assert.equal((await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves: swapped })).body.error, "moves_changed");
  assert.equal((await call(ctx, "POST", "/run", beto, { run_id: st.body.run_id, moves })).status, 404, "la partida es de Ana");
  const bad = structuredClone(moves);
  bad[7].cells = [0, 7];
  const r = await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves: bad });
  assert.equal(r.status, 422);
  assert.equal(r.body.error, "bad_chain");
  assert.equal((await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves })).body.error, "run_closed", "rechazada queda cerrada");
  // 20 cadenas en 24 s de juego, mandadas 5 s después de empezar: imposible.
  st = await call(ctx, "POST", "/daily/start", ana);
  moves = playFor(st.body.seed, 20);
  ctx.tick(5000);
  const fast = await call(ctx, "POST", "/run", ana, { run_id: st.body.run_id, moves, final: true });
  assert.equal(fast.body.error, "too_fast");
  const lb = await call(ctx, "GET", "/leaderboard", ana);
  assert.equal(lb.body.top.length <= 1, true);
});

test("las partidas de Godot dan el mismo puntaje por la API", async () => {
  // Con la semilla del vector en lugar de la del día: se fuerza en la base.
  const ctx = setup();
  for (const v of vectors) {
    const user = { id: 5000 + (v.seed % 1000), first_name: "V" };
    const st = await call(ctx, "POST", "/daily/start", user);
    await ctx.env.DB.prepare("UPDATE runs SET seed = ?2 WHERE id = ?1").bind(st.body.run_id, v.seed).run();
    ctx.tick(v.limit_ms);
    const r = await call(ctx, "POST", "/run", user, { run_id: st.body.run_id, moves: v.moves, final: true });
    assert.equal(r.body.score, v.score, `semilla ${v.seed}`);
  }
});
