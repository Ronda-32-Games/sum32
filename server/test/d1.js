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

export function makeD1() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../migrations/0001_init.sql", import.meta.url), "utf8"));
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
