// D1 de mentira para las pruebas: la misma interfaz (prepare, bind, first, all, run, batch)
// sobre el SQLite que trae Node. D1 también es SQLite, así que las consultas son las mismas.
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

class Stmt {
  constructor(db, sql, args = []) {
    this.db = db;
    this.sql = sql;
    this.args = args;
  }
  bind(...args) {
    return new Stmt(this.db, this.sql, args);
  }
  _exec() {
    return this.db.prepare(this.sql);
  }
  async first(col) {
    const row = this._exec().get(...this.args);
    if (!row) return null;
    return col ? row[col] : { ...row };
  }
  async all() {
    return { success: true, results: this._exec().all(...this.args).map((r) => ({ ...r })) };
  }
  async run() {
    const r = this._exec().run(...this.args);
    return { success: true, meta: { changes: Number(r.changes) } };
  }
}

// path: archivo para la base local de scripts/dev.js; sin path, en memoria (pruebas).
export function makeD1(path = ":memory:") {
  const db = new DatabaseSync(path);
  // user_version cuenta las migraciones ya corridas: la base local de dev.js no las repite.
  const files = ["0001_init.sql", "0002_analytics.sql"];
  const done = Number(db.prepare("PRAGMA user_version").get().user_version);
  files.slice(done).forEach((f) => db.exec(readFileSync(new URL(`../migrations/${f}`, import.meta.url), "utf8")));
  db.exec(`PRAGMA user_version = ${files.length}`);
  return {
    prepare: (sql) => new Stmt(db, sql),
    async batch(stmts) {
      db.exec("BEGIN");
      try {
        const out = [];
        for (const s of stmts) out.push(await s.run());
        db.exec("COMMIT");
        return out;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
  };
}
