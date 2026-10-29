// Analítica mínima (DEC-053, DEC-054): partidas con duración y "limpia", actividad, eventos,
// retención día 1 y 7, embudo, reintento, planillas y borrado de datos.
import { test } from "node:test";
import assert from "node:assert/strict";
import { USER_TABLES } from "../src/index.js";
import { config, day, makeWorld, call, playDay, playFor, person } from "./helpers.js";

const stats = (w, name, qs = "") => call(w, "GET", `/stats/${name}.json${qs}`, null, null, { Authorization: "Bearer test-stats-token" });
const count = async (w, table) => w.env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first("n");

test("con los eventos apagados no se guarda actividad ni eventos, pero las partidas sí", async () => {
  const w = makeWorld(false);
  await playDay(w, person(1), day("2026-10-20"));
  for (let k = 0; k < config.daily_free_attempts; k++) await call(w, "POST", "/daily/start", person(1));
  assert.equal(await count(w, "activity"), 0);
  assert.equal(await count(w, "events"), 0);
  assert.equal(await count(w, "runs") >= 1, true);
  assert.equal(await w.env.DB.prepare("SELECT username FROM users").first("username"), null, "no se guarda el @usuario");
});

test("partida: duración, tiempo real y limpia; abandonada y parcial no son limpias", async () => {
  const w = makeWorld(true);
  const u = person(1);
  w.at(day("2026-10-20"));
  const a = await call(w, "POST", "/daily/start", u);
  w.tick(30000);
  await call(w, "POST", "/run", u, { run_id: a.body.run_id, moves: playFor(a.body.seed, 4) }); // parcial
  let row = await w.env.DB.prepare("SELECT * FROM runs WHERE id = ?1").bind(a.body.run_id).first();
  assert.deepEqual([row.clean, row.duration_ms, row.wall_ms, row.status], [0, 0, 0, "open"]);
  const b = await call(w, "POST", "/daily/start", u); // la anterior queda abandonada
  row = await w.env.DB.prepare("SELECT * FROM runs WHERE id = ?1").bind(a.body.run_id).first();
  assert.deepEqual([row.clean, row.status, row.wall_ms], [0, "abandoned", 30000]);
  w.tick(65000);
  await call(w, "POST", "/run", u, { run_id: b.body.run_id, moves: playFor(b.body.seed, 6), final: true });
  row = await w.env.DB.prepare("SELECT * FROM runs WHERE id = ?1").bind(b.body.run_id).first();
  assert.equal(row.clean, 1);
  assert.equal(row.status, "done");
  assert.equal(row.duration_ms, 60000, "el reloj del juego: 60 s sin tiempo extra");
  assert.equal(row.wall_ms, 65000);
  assert.equal(row.mode, "daily");
  assert.equal(row.seed_source, "server");
});

test("retención día 1 y 7 con jugadores de prueba", async () => {
  const w = makeWorld(true);
  // Cohorte del 20/10: 10 jugadores. Vuelven el 21 seis, y el 27 tres. Cohorte del 27/10: 4 jugadores.
  for (let i = 0; i < 10; i++) await playDay(w, person(i), day("2026-10-20"));
  for (let i = 0; i < 6; i++) await playDay(w, person(i), day("2026-10-21"));
  for (const i of [0, 1, 8]) await playDay(w, person(i), day("2026-10-27"));
  for (let i = 20; i < 24; i++) await playDay(w, person(i), day("2026-10-27"));
  w.at(day("2026-10-28"));
  const r = (await stats(w, "retention")).body.rows;
  assert.deepEqual(r[0], { cohort_day: "2026-10-20", players: 10, d1_players: 6, d1_pct: 60, d7_players: 3, d7_pct: 30 });
  assert.deepEqual(r[1], { cohort_day: "2026-10-27", players: 4, d1_players: "", d1_pct: "", d7_players: "", d7_pct: "" }, "el 28 todavía no terminó");
  // El día 28 se completa: el día 1 de la cohorte del 27 ya se puede medir.
  await playDay(w, person(20), day("2026-10-28"));
  await playDay(w, person(21), day("2026-10-28"));
  w.at(day("2026-10-29"));
  const r2 = (await stats(w, "retention")).body.rows;
  assert.deepEqual([r2[1].d1_players, r2[1].d1_pct], [2, 50]);
});

test("embudo y reintento: llegar al tope se anota, y los reintentos de la v1 son cero", async () => {
  const w = makeWorld(true);
  for (let i = 0; i < 5; i++) await playDay(w, person(i), day("2026-10-20")); // 5 abren y juegan una vez
  // El jugador 0 gasta todos los intentos del día y toca uno más.
  const u = person(0);
  for (let k = 1; k < config.daily_free_attempts; k++) {
    const st = await call(w, "POST", "/daily/start", u);
    w.tick(61000);
    await call(w, "POST", "/run", u, { run_id: st.body.run_id, moves: playFor(st.body.seed, 3), final: true });
  }
  assert.equal((await call(w, "POST", "/daily/start", u)).status, 403);
  await playDay(w, person(0), day("2026-10-21")); // vuelve al otro día
  w.at(day("2026-10-22"));
  const f = (await stats(w, "funnel")).body.rows[0];
  assert.deepEqual(
    { opened: f.opened, first_game: f.first_game, started: f.daily_started, finished: f.daily_finished, no_attempts: f.no_attempts, ad_seen: f.ad_seen },
    { opened: 5, first_game: 5, started: 5, finished: 5, no_attempts: 1, ad_seen: 0 }
  );
  const n = await w.env.DB.prepare("SELECT n FROM events WHERE event = 'no_attempts'").first("n");
  assert.equal(n >= 2, true, "se cuenta cuando termina el último intento y cuando toca uno más");
  const rt = (await stats(w, "retry")).body.rows[0];
  assert.deepEqual(rt, { day: "2026-10-20", daily_players: 5, hit_wall: 1, hit_wall_pct: 20, came_back_next_day: 1, came_back_pct: 100, got_retry: 0, retry_pct: 0 });
});

test("planillas: CSV sin nombres ni números de Telegram, y con token", async () => {
  const w = makeWorld(true);
  for (let i = 0; i < 3; i++) await playDay(w, person(i), day("2026-10-20"));
  w.at(day("2026-10-21"));
  assert.equal((await call(w, "GET", "/stats/runs.csv")).status, 401);
  assert.equal((await call(w, "GET", "/stats/runs.csv", null, null, { Authorization: "Bearer otro" })).status, 401);
  assert.equal((await call(w, "GET", "/stats/nada.csv", null, null, { Authorization: "Bearer test-stats-token" })).status, 404);
  const csv = (await call(w, "GET", "/stats/runs.csv", null, null, { Authorization: "Bearer test-stats-token" })).text;
  const lines = csv.trim().split("\n");
  assert.equal(lines[0], "day,started_at,player,mode,seed_source,status,score,chains,best_chain,duration_ms,wall_ms,clean");
  assert.equal(lines.length, 4);
  const first = lines[1].split(",");
  assert.match(first[2], /^[0-9a-f]{12}$/);
  assert.equal(first[11], "1");
  for (const secret of ["Jugador", "Prueba", "user1", "2000", "2001"]) assert.equal(csv.includes(secret), false, `la planilla no puede tener ${secret}`);
  const again = (await call(w, "GET", "/stats/runs.csv", null, null, { Authorization: "Bearer test-stats-token" })).text;
  assert.equal(again, csv, "el mismo jugador sale siempre con el mismo código");
  const pl = (await call(w, "GET", "/stats/players.csv", null, null, { Authorization: "Bearer test-stats-token" })).text.trim().split("\n");
  assert.equal(pl[0], "player,first_day,last_day,days_active,daily_runs,best_score");
  assert.equal(pl.length, 4);
  const w2 = makeWorld(true);
  delete w2.env.STATS_TOKEN;
  assert.equal((await call(w2, "GET", "/stats/runs.csv", null, null, { Authorization: "Bearer test-stats-token" })).status, 404, "sin token configurado, no hay planillas");
});

test("borrar mis datos: no queda nada en ninguna tabla", async () => {
  const w = makeWorld(true);
  const a = person(1);
  const b = person(2);
  await playDay(w, a, day("2026-10-20"));
  await playDay(w, b, day("2026-10-20"));
  for (let k = 0; k < config.daily_free_attempts; k++) await call(w, "POST", "/daily/start", a); // llega al tope: evento
  // Las tablas con user_id son exactamente las que el borrado conoce.
  const tables = (await w.env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").all()).results.map((t) => t.name);
  const withUser = [];
  for (const t of tables) {
    const cols = (await w.env.DB.prepare(`SELECT name FROM pragma_table_info('${t}')`).all()).results.map((c) => c.name);
    if (cols.includes("user_id")) withUser.push(t);
  }
  assert.deepEqual(withUser.sort(), [...USER_TABLES].sort(), "una tabla nueva con user_id tiene que sumarse a USER_TABLES");
  for (const t of USER_TABLES) assert.equal((await w.env.DB.prepare(`SELECT COUNT(*) AS n FROM ${t} WHERE user_id = ?1`).bind(a.id).first("n")) > 0, true, `${t} tiene datos de a`);
  const del = await call(w, "DELETE", "/me", a);
  assert.deepEqual(del.body, { deleted: true });
  for (const t of USER_TABLES) assert.equal(await w.env.DB.prepare(`SELECT COUNT(*) AS n FROM ${t} WHERE user_id = ?1`).bind(a.id).first("n"), 0, `${t} sin datos de a`);
  assert.equal(await w.env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE id = ?1").bind(a.id).first("n"), 0);
  assert.equal(await w.env.DB.prepare("SELECT COUNT(*) AS n FROM runs WHERE user_id = ?1").bind(b.id).first("n") > 0, true, "b sigue");
  const lb = await call(w, "GET", "/leaderboard", b);
  assert.deepEqual(lb.body.top.map((r) => r.name), ["Jugador2 P."], "a desaparece del ranking");
  assert.equal((await call(w, "DELETE", "/me", null)).status, 401, "hace falta la firma de Telegram");
});
