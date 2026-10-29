// Servidor de Sum 32 (H2): Cloudflare Worker + D1 (TASK-026, DEC del 29/10).
// Endpoints:
//   GET  /health
//   POST /session       crea o actualiza al jugador; devuelve el estado del Daily
//   GET  /daily         día, intentos que quedan y mejor puntaje del día
//   POST /daily/start   gasta un intento y da la semilla del día (recién ahí se ve la grilla)
//   POST /run           recibe las jugadas, rehace la partida y guarda el puntaje
//   GET  /leaderboard   ranking diario (?day=AAAA-MM-DD, por defecto hoy)
//   DELETE /me          borra todo lo de quien pide (DEC-053)
//   GET  /stats/<informe>.csv|.json   planillas para Power BI (DEC-054); solo con STATS_TOKEN
// Todo pedido salvo /health y /stats lleva "Authorization: tma <initData>".
// Secretos del Worker (los carga Ignacio, nunca van al repo): BOT_TOKEN, DAILY_SECRET, STATS_TOKEN.
// Variables: ALLOWED_ORIGIN (la dirección del juego) y EVENTS_ENABLED ("true" enciende la
// actividad y los eventos; arranca apagado hasta que la página de privacidad esté publicada).

import config from "../../data/config.json" with { type: "json" };
import { replay } from "./rules.js";
import { verifyInitData, dailySeed } from "./telegram.js";
import { REPORTS, toCsv } from "./stats.js";

const RUN_MAX_MS = 2 * 60 * 60 * 1000; // una partida abierta se puede mandar hasta 2 h después
const CLOCK_SLACK_MS = 1000;           // el reloj del juego nunca corre más rápido que el real
const MAX_BODY = 64 * 1024;
const TOP = 50;
// Tablas con datos de una persona. Si se agrega una con user_id y no está acá, falla una prueba.
export const USER_TABLES = ["runs", "daily_best", "activity", "events"];
const eventsOn = (env) => String(env.EVENTS_ENABLED) === "true";

export const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);

export function attemptsAllowed(cfg) {
  // En v1 no hay anuncios ni Stars (DEC-049): solo los intentos gratis. Cuando vuelvan,
  // cada reintento ganado suma uno, hasta daily_extra_attempts.
  return Number(cfg.daily_free_attempts ?? 2);
}

function displayName(u) {
  const last = u.last_name ? ` ${u.last_name[0]}.` : "";
  return (`${u.first_name || u.username || "Player"}${last}`).slice(0, 24);
}

class HttpError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
  }
}

function cors(env, request) {
  const origin = request.headers.get("Origin") || "";
  const allowed = (env.ALLOWED_ORIGIN || "").split(",").map((s) => s.trim()).filter(Boolean);
  const h = { "Access-Control-Allow-Headers": "Authorization, Content-Type", "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS", "Access-Control-Max-Age": "86400", Vary: "Origin" };
  if (allowed.includes(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

const json = (status, body, headers) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

async function auth(request, env, now) {
  const h = request.headers.get("Authorization") || "";
  if (!h.startsWith("tma ")) throw new HttpError(401, "no_auth");
  const data = await verifyInitData(h.slice(4), env.BOT_TOKEN, now);
  if (!data) throw new HttpError(401, "bad_auth");
  return data;
}

async function readBody(request) {
  const text = await request.text();
  if (text.length > MAX_BODY) throw new HttpError(413, "too_big");
  try {
    return JSON.parse(text || "{}");
  } catch {
    throw new HttpError(400, "bad_json");
  }
}

async function upsertUser(env, u, now) {
  // Del @usuario no se guarda nada (DEC-053).
  await env.DB.prepare(
    `INSERT INTO users (id, name, username, created_at, last_seen) VALUES (?1, ?2, NULL, ?3, ?3)
     ON CONFLICT(id) DO UPDATE SET name = ?2, last_seen = ?3`
  ).bind(u.id, displayName(u), now).run();
}

// Una fila por jugador y día activo. Si ya existe no escribe nada.
async function markActive(env, userId, now) {
  if (!eventsOn(env)) return;
  await env.DB.prepare(`INSERT OR IGNORE INTO activity (user_id, day) VALUES (?1, ?2)`).bind(userId, dayOf(now)).run();
}

// Cuenta un evento del día. source: "server" o "reported" (lo avisó el juego).
async function bump(env, userId, event, now, source = "server") {
  if (!eventsOn(env)) return;
  await env.DB.prepare(
    `INSERT INTO events (user_id, day, event, n, first_at, last_at, source) VALUES (?1, ?2, ?3, 1, ?4, ?4, ?5)
     ON CONFLICT(user_id, day, event) DO UPDATE SET n = n + 1, last_at = ?4`
  ).bind(userId, dayOf(now), event, now, source).run();
}

async function dailyState(env, userId, now) {
  const day = dayOf(now);
  const used = await env.DB.prepare(`SELECT COUNT(*) AS n FROM runs WHERE user_id = ?1 AND day = ?2 AND mode = 'daily'`)
    .bind(userId, day).first("n");
  const best = await env.DB.prepare(`SELECT score, chains, best_chain FROM daily_best WHERE day = ?1 AND user_id = ?2`)
    .bind(day, userId).first();
  const allowed = attemptsAllowed(config);
  const nextDay = Date.parse(`${day}T00:00:00Z`) + 86400000;
  return { day, attempts_allowed: allowed, attempts_used: used, attempts_left: Math.max(0, allowed - used), best: best || null, resets_in_ms: nextDay - now };
}

async function startDaily(env, userId, now) {
  const st = await dailyState(env, userId, now);
  if (st.attempts_left <= 0) {
    await bump(env, userId, "no_attempts", now);
    throw new HttpError(403, "no_attempts");
  }
  const seed = await dailySeed(env.DAILY_SECRET, st.day);
  const id = crypto.randomUUID();
  // Una partida abierta que se abandonó queda con el puntaje que alcanzó a mandar.
  await env.DB.batch([
    env.DB.prepare(`UPDATE runs SET status = 'abandoned', wall_ms = updated_at - started_at, updated_at = ?2 WHERE user_id = ?1 AND status = 'open'`).bind(userId, now),
    env.DB.prepare(`INSERT INTO runs (id, user_id, mode, day, seed, started_at, status, updated_at) VALUES (?1, ?2, 'daily', ?3, ?4, ?5, 'open', ?5)`)
      .bind(id, userId, st.day, seed, now),
  ]);
  return { run_id: id, seed, day: st.day, attempts_left: st.attempts_left - 1 };
}

async function submitRun(env, userId, body, now) {
  const { run_id: runId, moves, final } = body;
  if (typeof runId !== "string") throw new HttpError(400, "no_run");
  const run = await env.DB.prepare(`SELECT * FROM runs WHERE id = ?1 AND user_id = ?2`).bind(runId, userId).first();
  if (!run) throw new HttpError(404, "no_run");
  if (run.status !== "open") throw new HttpError(409, "run_closed");
  if (now - run.started_at > RUN_MAX_MS) throw new HttpError(410, "run_expired");
  // Lo que ya se mandó no se puede cambiar: las jugadas nuevas siguen a las anteriores.
  const prev = JSON.parse(run.moves);
  if (!Array.isArray(moves) || moves.length < prev.length || JSON.stringify(moves.slice(0, prev.length)) !== JSON.stringify(prev)) {
    throw new HttpError(422, "moves_changed");
  }
  const r = replay(config, run.seed, moves);
  if (!r.ok || r.last_t > now - run.started_at + CLOCK_SLACK_MS) {
    await env.DB.prepare(`UPDATE runs SET status = 'rejected', updated_at = ?2 WHERE id = ?1`).bind(runId, now).run();
    throw new HttpError(422, r.ok ? "too_fast" : r.error);
  }
  const status = final ? "done" : "open";
  const stmts = [
    // clean = 1: el servidor rehizo la partida entera y dio igual (DEC-054).
    env.DB.prepare(`UPDATE runs SET moves = ?2, score = ?3, chains = ?4, best_chain = ?5, status = ?6, updated_at = ?7,
                    duration_ms = ?8, wall_ms = ?9, clean = ?10 WHERE id = ?1`)
      .bind(runId, JSON.stringify(moves), r.score, r.chains, r.best_chain, status, now,
        final ? r.limit_ms : 0, final ? now - run.started_at : 0, final ? 1 : 0),
  ];
  if (r.chains > 0) {
    stmts.push(env.DB.prepare(
      `INSERT INTO daily_best (day, user_id, score, chains, best_chain, run_id, at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT(day, user_id) DO UPDATE SET score = ?3, chains = ?4, best_chain = ?5, run_id = ?6, at = ?7
       WHERE excluded.score > daily_best.score`
    ).bind(run.day, userId, r.score, r.chains, r.best_chain, runId, now));
  }
  await env.DB.batch(stmts);
  const best = await env.DB.prepare(`SELECT score FROM daily_best WHERE day = ?1 AND user_id = ?2`).bind(run.day, userId).first("score");
  if (final && eventsOn(env) && (await dailyState(env, userId, now)).attempts_left === 0) await bump(env, userId, "no_attempts", now);
  const rank = best == null ? null : await rankOf(env, run.day, userId);
  return { score: r.score, chains: r.chains, best_chain: r.best_chain, status, day: run.day, day_best: best ?? 0, rank };
}

async function rankOf(env, day, userId) {
  const me = await env.DB.prepare(`SELECT score, at FROM daily_best WHERE day = ?1 AND user_id = ?2`).bind(day, userId).first();
  if (!me) return null;
  const ahead = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM daily_best WHERE day = ?1 AND (score > ?2 OR (score = ?2 AND at < ?3))`
  ).bind(day, me.score, me.at).first("n");
  return ahead + 1;
}

async function leaderboard(env, userId, day) {
  const { results } = await env.DB.prepare(
    `SELECT u.name, b.score, b.best_chain, b.user_id FROM daily_best b JOIN users u ON u.id = b.user_id
     WHERE b.day = ?1 ORDER BY b.score DESC, b.at ASC LIMIT ?2`
  ).bind(day, TOP).all();
  const players = await env.DB.prepare(`SELECT COUNT(*) AS n FROM daily_best WHERE day = ?1`).bind(day).first("n");
  const top = results.map((row, i) => ({ rank: i + 1, name: row.name, score: row.score, best_chain: row.best_chain, me: row.user_id === userId }));
  const rank = await rankOf(env, day, userId);
  const mine = rank == null ? null : await env.DB.prepare(`SELECT score FROM daily_best WHERE day = ?1 AND user_id = ?2`).bind(day, userId).first("score");
  return { day, players, top, me: rank == null ? null : { rank, score: mine } };
}

async function stats(request, env, url, path, now) {
  const m = /^\/stats\/([a-z_]+)\.(csv|json)$/.exec(path);
  if (!env.STATS_TOKEN || !m || !REPORTS[m[1]]) throw new HttpError(404, "not_found");
  const given = (request.headers.get("Authorization") || "").replace(/^Bearer /, "");
  if (given.length !== env.STATS_TOKEN.length || given !== env.STATS_TOKEN) throw new HttpError(401, "bad_token");
  const rows = await REPORTS[m[1]](env, { from: url.searchParams.get("from"), to: url.searchParams.get("to"), today: dayOf(now) });
  if (m[2] === "json") return { rows };
  return new Response(toCsv(rows), { status: 200, headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": `attachment; filename="sum32-${m[1]}-${dayOf(now)}.csv"` } });
}

async function deleteMe(env, userId) {
  await env.DB.batch([
    ...USER_TABLES.map((t) => env.DB.prepare(`DELETE FROM ${t} WHERE user_id = ?1`).bind(userId)),
    env.DB.prepare(`DELETE FROM users WHERE id = ?1`).bind(userId),
  ]);
  return { deleted: true };
}

async function route(request, env, now) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const method = request.method;
  if (path === "/health" && method === "GET") return { ok: true, day: dayOf(now) };
  if (path.startsWith("/stats/") && method === "GET") return stats(request, env, url, path, now);
  const tg = await auth(request, env, now);
  const uid = tg.user.id;
  if (path === "/me" && method === "DELETE") return deleteMe(env, uid);
  if (path === "/session" && method === "POST") {
    await upsertUser(env, tg.user, now);
    await markActive(env, uid, now);
    return { user: { id: uid, name: displayName(tg.user) }, daily: await dailyState(env, uid, now), start_param: tg.startParam };
  }
  if (path === "/daily" && method === "GET") return dailyState(env, uid, now);
  if (path === "/daily/start" && method === "POST") {
    await upsertUser(env, tg.user, now);
    await markActive(env, uid, now);
    return startDaily(env, uid, now);
  }
  if (path === "/run" && method === "POST") return submitRun(env, uid, await readBody(request), now);
  if (path === "/leaderboard" && method === "GET") {
    const day = url.searchParams.get("day") || dayOf(now);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new HttpError(400, "bad_day");
    return leaderboard(env, uid, day);
  }
  throw new HttpError(404, "not_found");
}

export default {
  async fetch(request, env) {
    const headers = cors(env, request);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    const now = env.clock ? env.clock() : Date.now(); // env.clock solo existe en las pruebas
    try {
      const out = await route(request, env, now);
      return out instanceof Response ? out : json(200, out, headers);
    } catch (e) {
      if (e instanceof HttpError) return json(e.status, { error: e.message }, headers);
      console.error(e);
      return json(500, { error: "server" }, headers);
    }
  },
};
