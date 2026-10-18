-- metrics/schema.sql — append-only metrics store (docs/PLAN.md §10).
-- Every metric value carries a `kind`: measured | estimated | not_attributable.
CREATE TABLE IF NOT EXISTS runs (
  id    INTEGER PRIMARY KEY,
  ts    INTEGER NOT NULL,     -- unix epoch
  flows TEXT,                 -- comma-separated flow list
  note  TEXT
);
CREATE TABLE IF NOT EXISTS metrics (
  id        INTEGER PRIMARY KEY,
  run_id    INTEGER NOT NULL REFERENCES runs(id),
  category  TEXT NOT NULL,    -- perf | coverage | resource | rr | ...
  name      TEXT NOT NULL,
  value     REAL,
  unit      TEXT,
  kind      TEXT NOT NULL CHECK (kind IN ('measured','estimated','not_attributable'))
);
