-- Sum 32, H2: usuarios, partidas Daily y mejor puntaje del día.
-- Del jugador guardamos lo mínimo: id de Telegram, nombre para el ranking y usuario.

CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,          -- id de Telegram
  name TEXT NOT NULL,
  username TEXT,
  created_at INTEGER NOT NULL,     -- ms
  last_seen INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL,
  mode TEXT NOT NULL,              -- daily
  day TEXT NOT NULL,               -- AAAA-MM-DD en UTC, el día en que empezó
  seed INTEGER NOT NULL,
  started_at INTEGER NOT NULL,
  status TEXT NOT NULL,            -- open, done, rejected
  moves TEXT NOT NULL DEFAULT '[]',
  score INTEGER NOT NULL DEFAULT 0,
  chains INTEGER NOT NULL DEFAULT 0,
  best_chain INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS runs_user_day ON runs (user_id, day);

CREATE TABLE IF NOT EXISTS daily_best (
  day TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  score INTEGER NOT NULL,
  chains INTEGER NOT NULL,
  best_chain INTEGER NOT NULL,
  run_id TEXT NOT NULL,
  at INTEGER NOT NULL,             -- cuándo lo logró: desempata a favor del primero
  PRIMARY KEY (day, user_id)
);
CREATE INDEX IF NOT EXISTS daily_best_rank ON daily_best (day, score DESC, at);
