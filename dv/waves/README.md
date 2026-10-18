# dv/waves — per-test GTKWave sessions

Committed `.gtkw` session files (one per directed test) plus `wave_check.py`,
which checks each session against a fresh VCD dump headlessly (no GUI needed).

**M0:** placeholder. Sessions + `wave_check.py` land in **M7** (docs/PLAN.md §11).
`make wave-<test>` dumps a VCD, checks the session, and opens GTKWave if a display
is available; `make wave-check-all` runs the headless check over every session.
