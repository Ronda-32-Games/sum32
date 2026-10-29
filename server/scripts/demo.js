// Demo con jugadores de mentira: simula dos semanas de Sum 32 en una base local y baja las
// planillas como las bajaría Power BI. No usa ni toca datos reales.
//   node scripts/demo.js ../ruta/de/salida
import { mkdirSync, writeFileSync } from "node:fs";
import { Mulberry32 } from "../src/rules.js";
import { makeWorld, call, day, playFor } from "../test/helpers.js";

const out = process.argv[2] || "demo-out";
mkdirSync(out, { recursive: true });
const rng = new Mulberry32(20261029);
const chance = (p) => rng.nextU32() / 4294967296 < p;
const w = makeWorld(true);
const FIRST = "2026-10-15";
const DAYS = 14;
const players = [];

async function session(p, d) {
  w.at(day(d, 10 + (rng.nextU32() % 12)));
  await call(w, "POST", "/session", p.user);
}

async function playOne(p, finish = true) {
  const st = await call(w, "POST", "/daily/start", p.user);
  if (st.status !== 200) return false;
  w.tick(61000);
  if (finish) {
    const chains = Math.max(3, Math.min(34, Math.round(p.skill + (rng.nextU32() % 9) - 4)));
    await call(w, "POST", "/run", p.user, { run_id: st.body.run_id, moves: playFor(st.body.seed, chains), final: true });
  }
  return true;
}

for (let k = 0; k < DAYS; k++) {
  const d = new Date(Date.parse(`${FIRST}T00:00:00Z`) + k * 86400000).toISOString().slice(0, 10);
  const fresh = 25 + (rng.nextU32() % 20) + (k === 5 ? 40 : 0); // el día 5 sale el post del canal
  for (let i = 0; i < fresh; i++) {
    const id = 7000 + players.length;
    players.push({ user: { id, first_name: `Demo${id}` }, skill: 8 + (rng.nextU32() % 22), loyalty: 0.15 + (rng.nextU32() % 50) / 100, joined: k });
  }
  for (const p of players) {
    const age = k - p.joined;
    const returns = age === 0 || chance(p.loyalty * Math.pow(0.93, age));
    if (!returns) continue;
    await session(p, d);
    if (age === 0 && !chance(0.8)) continue; // uno de cada cinco abre el juego y no juega
    const runs = 1 + (chance(0.45) ? 1 : 0) + (chance(0.25) ? 1 : 0) + (chance(0.15) ? 1 : 0);
    for (let r = 0; r < runs; r++) {
      if (chance(0.08)) await playOne(p, false); // abandona a la mitad
      if (!(await playOne(p))) break;
    }
  }
}

w.at(day("2026-10-29", 9)); // el día siguiente al último simulado: su día 1 todavía no se puede medir
for (const name of ["retention", "funnel", "retry", "runs", "players"]) {
  const res = await call(w, "GET", `/stats/${name}.csv`, null, null, { Authorization: "Bearer test-stats-token" });
  writeFileSync(`${out}/demo-${name}.csv`, res.text);
  console.log(name, res.text.trim().split("\n").length - 1, "filas");
}
const written = await w.env.DB.prepare("SELECT (SELECT COUNT(*) FROM users) u, (SELECT COUNT(*) FROM runs) r, (SELECT COUNT(*) FROM activity) a, (SELECT COUNT(*) FROM events) e").first();
console.log("filas en la base:", JSON.stringify(written));
