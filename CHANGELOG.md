# Changelog

## 0.2.0 — 2026-09-28

- Added a public, I/O-free `query` package: validated query plans, nested JSON Pointer fields, typed AND filters, multiple group dimensions and numeric metrics.
- Added incremental accumulation and independent snapshots with bounded invalid-line diagnostics, explicit group/line limits and atomic overflow failures.
- Added a native streaming file/stdin query CLI, preserving the HTTP CLI and API.
- Added job, build and sensor examples, a direct library embedding example, public API tests and native CLI integration checks.
- Extended CI to exercise the new query workflow. Numeric values remain IEEE-754 doubles; exact arbitrary-precision arithmetic, plain-text parsing and a live dashboard are outside this release.

## 0.1.0 — 2026-09-24

Initial HTTP JSONL validation, filtering, error-rate and exact percentile reporting, CI gates and public Mooncakes release.
