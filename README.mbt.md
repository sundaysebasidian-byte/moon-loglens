# Moon LogLens

Moon LogLens is a small native MoonBit command-line tool for checking JSONL request logs before investigating an outage or gating a CI run. It turns raw request events into per-service and per-status counts, 5xx error rates, and latency percentiles. Invalid lines are counted separately, with line numbers but without log payloads in the report.

This is a standalone log-analysis workflow. The parsing, validation, filtering, aggregation, and output formatting are written in MoonBit. File I/O uses [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async); the CLI targets native execution.

## Quick start

Install the [MoonBit toolchain](https://docs.moonbitlang.com/en/stable/tutorial/cli-quickstart.html) and run these commands from the repository root:

```sh
moon update
moon test --target native
python3 tests/cli_smoke.py
moon run cmd/main examples/requests.jsonl
moon run cmd/main examples/requests.jsonl --service api --level ERROR --format json
moon run cmd/main examples/requests.jsonl --status 503 --format json
moon run cmd/main examples/requests.jsonl --min-events 1 --fail-on-invalid --max-error-rate 20
moon run cmd/main examples/requests.jsonl --max-p95-ms 100
moon run cmd/main examples/requests.jsonl --max-service-error-rate 30
```

On Windows PowerShell, install MoonBit, add `moon` to `PATH`, and use the same `moon` commands. If Python is installed, run the integration checks with `py tests\cli_smoke.py`. The project owner ran the guarded check/build/test and CLI smoke workflow on Windows against commit `91a848e` on 2026-09-24; the shared output shows all five Python integration tests passing and the expected sample report. The native macOS test suite also passed. Linux has not been tested.

Sample text output starts with:

```text
accepted=4 filtered=0 invalid=1 errors=1 error_rate_pct=25 p50_ms=20 p95_ms=150
invalid_lines=5
service="api" requests=3 errors=1 error_rate_pct=33.333333333333336 p50_ms=20 p95_ms=150
```

The example deliberately contains one malformed line. A nonzero `invalid` count does not automatically fail a normal report; review `invalid_lines` and fix the source data as appropriate. The final command above demonstrates a CI gate and exits with code 4 because of that malformed line.

## Input contract

The input is UTF-8 JSON Lines: one JSON object per nonblank line. Every event requires the following fields:

| Field | Type and rule |
| --- | --- |
| `timestamp` | A valid UTC timestamp in whole seconds (`2026-09-24T03:00:00Z`) or exactly three fractional digits (`2026-09-24T03:00:00.250Z`); no offsets or leap seconds. |
| `service` | A nonblank string. |
| `level` | Exactly `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `status` | An integer HTTP status from 100 through 599. |
| `latency_ms` | A finite number from 0 through 86,400,000. |

Extra fields are ignored. Blank lines are ignored. Invalid nonblank lines remain visible through `invalid` and `invalid_lines`, even when filters are active. Physical line numbers start at 1.

## Filters and report

```text
moon run cmd/main <input.jsonl> [--service NAME] [--level DEBUG|INFO|WARN|ERROR]
  [--status 100..599]
  [--since YYYY-MM-DDTHH:MM:SSZ] [--until YYYY-MM-DDTHH:MM:SSZ]
  [--format text|json] [--max-error-rate PERCENT] [--max-service-error-rate PERCENT]
  [--max-p95-ms MILLISECONDS]
  [--min-events COUNT] [--fail-on-invalid]
```

Time bounds are inclusive and accept the same second or millisecond UTC forms. Whole seconds are treated as `.000Z`: an `--until` bound at `03:00:00Z` excludes events later within that second. `--status` selects one exact HTTP response code. Valid events excluded by filters increment `filtered`, not `invalid`. Counts, percentiles, and error rates use accepted events only. `errors` counts HTTP 5xx statuses; 4xx responses are not counted as server errors. `error_rate_pct = errors / accepted * 100`, with zero for an empty selection. The P50 and P95 calculations use the nearest-rank method on sorted latency values, including the overall P50/P95 in the first report line. Results are grouped by service and exact HTTP status; groups are sorted for stable output. Service names in text output are JSON-quoted so control characters cannot create false report lines. JSON output contains the same data as text output.

`--max-error-rate` compares the overall percentage after filtering and fails if no events were accepted, because an empty sample cannot prove a healthy error rate. `--max-service-error-rate` checks every accepted service group, catching one unhealthy service that a healthy overall rate could hide; it also fails on an empty sample. `--max-p95-ms` compares the overall P95 latency after filtering and also fails on an empty sample. `--min-events` sets a positive minimum accepted sample count. `--fail-on-invalid` rejects any malformed nonblank row, including rows outside the requested filters. All gates still write the report to standard output for CI artifacts. Exit codes are 0 for a successful report, 1 when the input file cannot be read, 2 for a CLI or filter error, 3 for a failed overall error-rate gate or an empty error-rate sample, 4 for invalid rows under `--fail-on-invalid`, 5 for too few accepted events under `--min-events`, 6 for a failed P95 gate, and 7 for a failed per-service error-rate gate. If several gates fail, invalid rows take priority, then sample count, overall error rate, P95, and per-service error rate.

## Scope and limits

The current implementation reads the whole file and keeps selected events in memory, so it is intended for bounded local logs and CI artifacts rather than unbounded streams. It does not parse arbitrary logging formats, normalize timezone offsets, infer missing fields, or redact arbitrary extra fields in the input file; reports never echo raw lines. `--max-error-rate` checks only accepted events. The tool does not send data over the network.

## Development

```sh
moon check --target native
moon test --target native
moon build --target native
moon info
moon fmt
```

The MoonBit tests cover calendar and schema validation, invalid-line accounting, filters, aggregation, percentile boundaries, empty input, and JSON serialization. The optional Python standard-library integration tests exercise the actual CLI, JSON output, and exit codes. See [`examples/requests.jsonl`](examples/requests.jsonl) for a reproducible demo. Licensed under Apache-2.0.
