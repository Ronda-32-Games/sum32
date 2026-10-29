-- Sum 32, analítica mínima (DEC-053, DEC-054). Pensada para escribir pocas filas:
--  - activity: una fila por jugador y día activo (sirve para retención)
--  - events: una fila por jugador, día y tipo de evento, con un contador
-- Las dos tablas son WITHOUT ROWID: no llevan índice aparte, así cada fila cuenta una sola vez
-- en las escrituras de D1.

ALTER TABLE runs ADD COLUMN seed_source TEXT NOT NULL DEFAULT 'server'; -- server o client
ALTER TABLE runs ADD COLUMN duration_ms INTEGER NOT NULL DEFAULT 0;     -- reloj del juego, con el tiempo extra
ALTER TABLE runs ADD COLUMN wall_ms INTEGER NOT NULL DEFAULT 0;         -- tiempo real de empezar a terminar
ALTER TABLE runs ADD COLUMN clean INTEGER NOT NULL DEFAULT 0;           -- 1: el servidor rehizo la partida y dio igual

-- Se deja de guardar el @usuario (DEC-053): no se usa para nada.
UPDATE users SET username = NULL;

CREATE TABLE IF NOT EXISTS activity (
  user_id INTEGER NOT NULL,
  day TEXT NOT NULL,                -- AAAA-MM-DD en UTC
  PRIMARY KEY (user_id, day)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS events (
  user_id INTEGER NOT NULL,
  day TEXT NOT NULL,
  event TEXT NOT NULL,              -- no_attempts, y los que vengan: ad_seen, stars_purchase, challenge_sent...
  n INTEGER NOT NULL DEFAULT 1,     -- cuántas veces ese día
  first_at INTEGER NOT NULL,        -- ms
  last_at INTEGER NOT NULL,
  source TEXT NOT NULL DEFAULT 'server',  -- server o reported (lo avisó el juego)
  PRIMARY KEY (user_id, day, event)
) WITHOUT ROWID;
