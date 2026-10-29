// Reglas de Sum 32 en JavaScript, igual que scripts/rng.gd, board.gd y round.gd.
// El servidor rehace cada partida con esto. Si cambia una regla en Godot, cambia acá
// también: tests/round_vectors.json (lo escribe Godot) tiene que dar igual en los dos lados.

export function derive(seed, salt) {
  let h = (seed ^ Math.imul(salt + 1, 0x9e3779b1)) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 0x85ebca6b) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35) >>> 0;
  return (h ^ (h >>> 16)) >>> 0;
}

export class Mulberry32 {
  constructor(seed) {
    this.state = seed >>> 0;
  }
  nextU32() {
    this.state = (this.state + 0x6d2b79f5) >>> 0;
    let t = Math.imul(this.state ^ (this.state >>> 15), 1 | this.state) >>> 0;
    t = ((t + Math.imul(t ^ (t >>> 7), 61 | t)) >>> 0) ^ t;
    return (t ^ (t >>> 14)) >>> 0;
  }
  rangeInt(lo, hi) {
    return lo + (this.nextU32() % (hi - lo + 1));
  }
}

const num = (cfg, key, def) => (cfg[key] === undefined ? def : Number(cfg[key]));

export class Board {
  constructor(cfg, seed) {
    this.size = num(cfg, "grid_size", 6);
    this.target = num(cfg, "target_sum", 32);
    this.vmin = num(cfg, "value_min", 3);
    this.vmax = num(cfg, "value_max", 12);
    this.seed = seed >>> 0;
    this.shuffleCount = 0;
    const n = this.size;
    this.cells = new Array(n * n).fill(0);
    this.rngs = [];
    for (let c = 0; c < n; c++) this.rngs.push(new Mulberry32(derive(this.seed, c)));
    for (let c = 0; c < n; c++) for (let r = 0; r < n; r++) this.cells[r * n + c] = this.next(c);
    this.ensurePlayable();
  }
  next(col) {
    return this.rngs[col].rangeInt(this.vmin, this.vmax);
  }
  adjacent(a, b) {
    const n = this.size;
    return Math.abs(Math.floor(a / n) - Math.floor(b / n)) + Math.abs((a % n) - (b % n)) === 1;
  }
  isValidChain(chain) {
    if (!Array.isArray(chain) || chain.length < 2) return false;
    const seen = new Set();
    let sum = 0;
    for (let k = 0; k < chain.length; k++) {
      const i = chain[k];
      if (!Number.isInteger(i) || i < 0 || i >= this.cells.length || seen.has(i)) return false;
      seen.add(i);
      if (k > 0 && !this.adjacent(chain[k - 1], i)) return false;
      sum += this.cells[i];
    }
    return sum === this.target;
  }
  clearChain(chain) {
    const n = this.size;
    const removed = new Set(chain);
    for (let c = 0; c < n; c++) {
      const kept = [];
      for (let r = n - 1; r >= 0; r--) {
        const i = r * n + c;
        if (!removed.has(i)) kept.push(this.cells[i]);
      }
      let w = n - 1;
      for (const v of kept) this.cells[w-- * n + c] = v;
      while (w >= 0) this.cells[w-- * n + c] = this.next(c);
    }
    this.ensurePlayable();
  }
  findAnyChain() {
    for (let s = 0; s < this.cells.length; s++) {
      const found = this.dfs([s], this.cells[s]);
      if (found) return found;
    }
    return null;
  }
  dfs(path, total) {
    if (total === this.target && path.length >= 2) return path;
    if (total >= this.target) return null;
    const n = this.size;
    const last = path[path.length - 1];
    const r = Math.floor(last / n);
    const c = last % n;
    for (const [dr, dc] of [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
      const nr = r + dr;
      const nc = c + dc;
      if (nr < 0 || nr >= n || nc < 0 || nc >= n) continue;
      const i = nr * n + nc;
      if (path.includes(i)) continue;
      const res = this.dfs([...path, i], total + this.cells[i]);
      if (res) return res;
    }
    return null;
  }
  ensurePlayable() {
    let tries = 0;
    while (!this.findAnyChain() && tries < 20) {
      this.shuffleCount++;
      tries++;
      const rng = new Mulberry32(derive(this.seed, 1000 + this.shuffleCount));
      for (let i = this.cells.length - 1; i > 0; i--) {
        const j = rng.nextU32() % (i + 1);
        [this.cells[i], this.cells[j]] = [this.cells[j], this.cells[i]];
      }
    }
  }
}

// Rehace una partida a partir de sus jugadas [{cells:[...], t: ms}].
// Devuelve {ok:true, score, chains, best_chain, limit_ms} o {ok:false, error, move}.
export function replay(cfg, seed, moves, maxMoves = 400) {
  if (!Array.isArray(moves)) return { ok: false, error: "moves_not_list" };
  if (moves.length > maxMoves) return { ok: false, error: "too_many_moves" };
  const board = new Board(cfg, seed);
  let limit = num(cfg, "round_seconds", 60) * 1000;
  const factor = num(cfg, "points_factor", 10);
  const window = num(cfg, "combo_window_s", 3) * 1000;
  const step = num(cfg, "combo_step_tenths", 5);
  const max = num(cfg, "combo_max_tenths", 30);
  const longLen = num(cfg, "long_chain_len", 6);
  const longBonus = num(cfg, "long_chain_bonus_s", 2) * 1000;
  let elapsed = 0;
  let score = 0;
  let chains = 0;
  let best = 0;
  let combo = 10;
  let lastClear = -1;
  for (let k = 0; k < moves.length; k++) {
    const m = moves[k];
    const t = m && m.t;
    if (!Number.isInteger(t) || t < elapsed) return { ok: false, error: "bad_time", move: k };
    if (t >= limit) return { ok: false, error: "after_end", move: k };
    elapsed = t;
    const chain = m.cells;
    if (!board.isValidChain(chain)) return { ok: false, error: "bad_chain", move: k };
    const n = chain.length;
    combo = lastClear >= 0 && elapsed - lastClear <= window ? Math.min(max, combo + step) : 10;
    score += Math.floor((factor * n * n * combo) / 10);
    chains++;
    best = Math.max(best, n);
    if (n >= longLen) limit += longBonus;
    lastClear = elapsed;
    board.clearChain(chain);
  }
  return { ok: true, score, chains, best_chain: best, limit_ms: limit, last_t: elapsed, grid_end: board.cells };
}
