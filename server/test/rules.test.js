// Las reglas en JavaScript dan lo mismo que Godot (vectores escritos por tests/run_tests.gd).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Mulberry32, derive, Board, replay } from "../src/rules.js";

const root = new URL("../../", import.meta.url);
const read = (p) => JSON.parse(readFileSync(new URL(p, root), "utf8"));
const cfg = read("data/config.json");

test("mulberry32 y derive igual que la referencia", () => {
  const exp = read("tests/rng_expected.json");
  for (const [seed, values] of Object.entries(exp.mulberry32)) {
    const g = new Mulberry32(Number(seed));
    assert.deepEqual(values.map(() => g.nextU32()), values);
  }
  for (const [seed, salt, v] of exp.derive) assert.equal(derive(seed, salt), v);
});

test("grilla y caídas igual que Godot", () => {
  for (const e of read("tests/board_vectors.json")) {
    const b = new Board(cfg, e.seed);
    assert.deepEqual(b.cells, e.grid, `grilla de la semilla ${e.seed}`);
    for (const m of e.moves) {
      assert.ok(b.isValidChain(m.chain));
      b.clearChain(m.chain);
      assert.deepEqual(b.cells, m.grid_after, `después de ${m.chain}`);
    }
  }
});

test("partidas completas: mismo puntaje que Godot", () => {
  for (const e of read("tests/round_vectors.json")) {
    const r = replay(cfg, e.seed, e.moves);
    assert.equal(r.ok, true, `semilla ${e.seed}: ${r.error} en ${r.move}`);
    assert.equal(r.score, e.score);
    assert.equal(r.chains, e.chains);
    assert.equal(r.best_chain, e.best_chain);
    assert.equal(r.limit_ms, e.limit_ms);
    assert.deepEqual(r.grid_end, e.grid_end);
  }
});

test("rechaza lo imposible", () => {
  const e = read("tests/round_vectors.json")[0];
  const copy = () => structuredClone(e.moves);
  let m = copy();
  m[3].cells = [0, 7];
  assert.equal(replay(cfg, e.seed, m).error, "bad_chain", "diagonal o suma distinta de 32");
  m = copy();
  m[5].t = m[4].t - 1;
  assert.equal(replay(cfg, e.seed, m).error, "bad_time", "jugada antes que la anterior");
  m = copy();
  m.push({ cells: m[0].cells, t: e.limit_ms });
  assert.equal(replay(cfg, e.seed, m).error, "after_end", "jugada después del final");
  m = copy();
  m.push(structuredClone(m[m.length - 1]));
  assert.equal(replay(cfg, e.seed, m).ok, false, "repetir la última jugada");
  assert.equal(replay(cfg, e.seed + 1, e.moves).ok, false, "otra semilla, otra grilla");
  assert.equal(replay(cfg, e.seed, "x").error, "moves_not_list");
});

test("rehacer una partida entra en 10 ms de CPU", () => {
  const vecs = read("tests/round_vectors.json");
  const t0 = performance.now();
  for (let k = 0; k < 20; k++) for (const e of vecs) replay(cfg, e.seed, e.moves);
  const per = (performance.now() - t0) / (20 * vecs.length);
  console.log(`  rehacer una partida: ${per.toFixed(2)} ms`);
  assert.ok(per < 5, `${per} ms por partida`);
});
