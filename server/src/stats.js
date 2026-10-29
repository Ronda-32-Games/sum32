// Informes para Power BI (DEC-054). Todos salen como planilla (CSV) o JSON, sin nombres ni
// números de Telegram: cada jugador es un código de 12 letras que no se puede deshacer sin el
// secreto del servidor, pero que es siempre el mismo para la misma persona.
//
// Informes: retention, funnel, retry, runs, players. Los días son UTC, igual que el Daily.
// ?from=AAAA-MM-DD&to=AAAA-MM-DD acota por día (por defecto, los últimos 90 días).

import { pseudonym } from "./telegram.js";

const MAX_ROWS = 5000; // el plan gratis de Workers da 10 ms de CPU por pedido
const DAY = /^\d{4}-\d{2}-\d{2}$/;

function range(q) {
  const today = q.today;
  const back = new Date(Date.parse(`${today}T00:00:00Z`) - 90 * 86400000).toISOString().slice(0, 10);
  const from = q.from && DAY.test(q.from) ? q.from : back;
  const to = q.to && DAY.test(q.to) ? q.to : today;
  return { from, to };
}

const pct = (x, n) => (x == null || !n ? "" : Math.round((1000 * x) / n) / 10);

export function toCsv(rows) {
  if (!rows.length) return "";
  const cols = Object.keys(rows[0]);
  const cell = (v) => {
    if (v == null) return "";
    const t = String(v);
    return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
  };
  return [cols.join(","), ...rows.map((r) => cols.map((c) => cell(r[c])).join(","))].join("\n") + "\n";
}

async function all(env, sql, ...args) {
  return (await env.DB.prepare(sql).bind(...args).all()).results;
}

// Retención: de quienes aparecieron por primera vez el día X, cuántos volvieron justo el X+1
// y justo el X+7. Un día solo cuenta cuando ya terminó; si no, la celda queda vacía.
async function retention(env, q) {
  const { from, to } = range(q);
  const rows = await all(
    env,
    `SELECT c.d0 AS cohort_day, COUNT(*) AS players,
            CASE WHEN date(c.d0, '+1 day') < ?1 THEN SUM(EXISTS(SELECT 1 FROM activity a WHERE a.user_id = c.user_id AND a.day = date(c.d0, '+1 day'))) END AS d1_players,
            CASE WHEN date(c.d0, '+7 day') < ?1 THEN SUM(EXISTS(SELECT 1 FROM activity a WHERE a.user_id = c.user_id AND a.day = date(c.d0, '+7 day'))) END AS d7_players
     FROM (SELECT user_id, MIN(day) AS d0 FROM activity GROUP BY user_id) c
     WHERE c.d0 BETWEEN ?2 AND ?3
     GROUP BY c.d0 ORDER BY c.d0`,
    q.today, from, to
  );
  return rows.map((r) => ({
    cohort_day: r.cohort_day, players: r.players,
    d1_players: r.d1_players ?? "", d1_pct: pct(r.d1_players, r.players),
    d7_players: r.d7_players ?? "", d7_pct: pct(r.d7_players, r.players),
  }));
}

// Embudo por día: cuántos jugadores distintos llegaron a cada paso.
async function funnel(env, q) {
  const { from, to } = range(q);
  const days = new Map();
  const row = (d) => {
    if (!days.has(d)) days.set(d, { day: d, opened: 0, first_game: 0, daily_started: 0, daily_finished: 0, no_attempts: 0, ad_seen: 0, stars_purchase: 0, challenge_sent: 0, challenge_accepted: 0 });
    return days.get(d);
  };
  for (const r of await all(env, `SELECT day, COUNT(*) AS n FROM activity WHERE day BETWEEN ?1 AND ?2 GROUP BY day`, from, to)) row(r.day).opened = r.n;
  for (const r of await all(env, `SELECT day, COUNT(DISTINCT user_id) AS started, COUNT(DISTINCT CASE WHEN clean = 1 THEN user_id END) AS finished
                                  FROM runs WHERE mode = 'daily' AND day BETWEEN ?1 AND ?2 GROUP BY day`, from, to)) {
    row(r.day).daily_started = r.started;
    row(r.day).daily_finished = r.finished;
  }
  for (const r of await all(env, `SELECT first_day AS day, COUNT(*) AS n FROM (SELECT user_id, MIN(day) AS first_day FROM runs WHERE clean = 1 GROUP BY user_id)
                                  WHERE first_day BETWEEN ?1 AND ?2 GROUP BY first_day`, from, to)) row(r.day).first_game = r.n;
  for (const r of await all(env, `SELECT day, event, COUNT(*) AS users FROM events WHERE day BETWEEN ?1 AND ?2 GROUP BY day, event`, from, to)) {
    if (r.event in row(r.day)) row(r.day)[r.event] = r.users;
  }
  return [...days.values()].sort((a, b) => (a.day < b.day ? -1 : 1));
}

// Conversión a reintento: de quienes se quedaron sin intentos, cuántos consiguieron un reintento
// y cuántos volvieron al día siguiente. En la v1 no hay reintentos (DEC-052): got_retry da 0 y
// came_back_next_day es la demanda.
async function retry(env, q) {
  const { from, to } = range(q);
  const rows = await all(
    env,
    `SELECT e.day AS day, COUNT(*) AS hit_wall,
            CASE WHEN date(e.day, '+1 day') < ?1 THEN SUM(EXISTS(SELECT 1 FROM activity a WHERE a.user_id = e.user_id AND a.day = date(e.day, '+1 day'))) END AS came_back_next_day,
            SUM(EXISTS(SELECT 1 FROM events r WHERE r.user_id = e.user_id AND r.day = e.day AND r.event = 'retry_granted')) AS got_retry
     FROM events e WHERE e.event = 'no_attempts' AND e.day BETWEEN ?2 AND ?3 GROUP BY e.day ORDER BY e.day`,
    q.today, from, to
  );
  const played = new Map((await all(env, `SELECT day, COUNT(DISTINCT user_id) AS n FROM runs WHERE mode = 'daily' AND day BETWEEN ?1 AND ?2 GROUP BY day`, from, to)).map((r) => [r.day, r.n]));
  return rows.map((r) => ({
    day: r.day, daily_players: played.get(r.day) ?? 0, hit_wall: r.hit_wall,
    hit_wall_pct: pct(r.hit_wall, played.get(r.day)),
    came_back_next_day: r.came_back_next_day ?? "", came_back_pct: pct(r.came_back_next_day, r.hit_wall),
    got_retry: r.got_retry, retry_pct: pct(r.got_retry, r.hit_wall),
  }));
}

// Cada partida, con el jugador en código.
async function runs(env, q, secret = q.secret) {
  const { from, to } = range(q);
  const rows = await all(
    env,
    `SELECT day, started_at, user_id, mode, seed_source, status, score, chains, best_chain, duration_ms, wall_ms, clean
     FROM runs WHERE day BETWEEN ?1 AND ?2 ORDER BY started_at LIMIT ?3`,
    from, to, MAX_ROWS
  );
  const out = [];
  for (const r of rows) {
    out.push({
      day: r.day, started_at: new Date(r.started_at).toISOString(), player: await pseudonym(secret, r.user_id),
      mode: r.mode, seed_source: r.seed_source, status: r.status, score: r.score, chains: r.chains,
      best_chain: r.best_chain, duration_ms: r.duration_ms, wall_ms: r.wall_ms, clean: r.clean,
    });
  }
  return out;
}

// Un renglón por jugador.
async function players(env, q, secret = q.secret) {
  const rows = await all(
    env,
    `SELECT u.id AS user_id, date(u.created_at / 1000, 'unixepoch') AS first_day, date(u.last_seen / 1000, 'unixepoch') AS last_day,
            (SELECT COUNT(*) FROM activity a WHERE a.user_id = u.id) AS days_active,
            (SELECT COUNT(*) FROM runs r WHERE r.user_id = u.id AND r.mode = 'daily') AS daily_runs,
            (SELECT MAX(score) FROM runs r WHERE r.user_id = u.id AND r.clean = 1) AS best_score
     FROM users u ORDER BY u.created_at LIMIT ?1`,
    MAX_ROWS
  );
  const out = [];
  for (const r of rows) {
    out.push({ player: await pseudonym(secret, r.user_id), first_day: r.first_day, last_day: r.last_day, days_active: r.days_active, daily_runs: r.daily_runs, best_score: r.best_score ?? "" });
  }
  return out;
}

// Cada informe recibe (env, {from, to, today}) y usa env.DAILY_SECRET para los códigos.
export const REPORTS = {
  retention,
  funnel,
  retry,
  runs: (env, q) => runs(env, q, env.DAILY_SECRET),
  players: (env, q) => players(env, q, env.DAILY_SECRET),
};
