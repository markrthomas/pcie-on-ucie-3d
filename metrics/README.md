# metrics — SQLite metrics store + dashboard

- `schema.sql` → `metrics.db` (append-only). Every value carries a `kind`:
  `measured` / `estimated` / `not_attributable` — **never fabricate a measured
  number**; record the gap.
- `collect.py` runs + times the flows and records real artifacts.
- `dashboard.py` renders `metrics.db` → `dashboard.html`.

`metrics.db` and `dashboard.html` are committed; per-run captures are not
(see `.gitignore`). **M0:** scaffold — the per-flow collectors and the
throughput/coverage/resource sections land in M7 (docs/PLAN.md §10–§11).
