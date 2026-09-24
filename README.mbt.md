# Moon LogLens

Moon LogLens is a small native MoonBit command-line tool for checking JSONL request logs before investigating an outage or gating a CI run. It turns raw request events into per-service and per-status counts, 5xx error rates, and latency percentiles. Invalid lines are counted separately, with line numbers but without log payloads in the report.

This is a standalone log-analysis workflow. The parsing, validation, filtering, aggregation, and output formatting are written in MoonBit. File I/O uses [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async); the CLI targets native execution.

## Quick start

Install the [MoonBit toolchain](https://docs.moonbitlang.com/en/stable/tutorial/cli-quickstart.html) and run these commands from the repository root:

```sh
moon update
moon test --target native
moon run cmd/main examples/requests.jsonl
moon run cmd/main examples/requests.jsonl --service api --level ERROR --format json
```

On Windows PowerShell, install MoonBit, add `moon` to `PATH`, and use the same `moon` commands. This revision was tested on macOS native; Windows execution has not yet been verified.

Sample text output starts with:

```text
accepted=4 filtered=0 invalid=1 errors=1 error_rate_pct=25
invalid_lines=5
service="api" requests=3 errors=1 error_rate_pct=33.333333333333336 p50_ms=20 p95_ms=150
```

The example deliberately contains one malformed line. A nonzero `invalid` count does not automatically fail the command; review `invalid_lines` and fix the source data as appropriate.

## Input contract

The input is UTF-8 JSON Lines: one JSON object per nonblank line. Every event requires the following fields:

| Field | Type and rule |
| --- | --- |
| `timestamp` | A valid fixed-width UTC timestamp such as `2026-09-24T03:00:00Z`; no offsets, fractions, or leap seconds. |
| `service` | A nonblank string. |
| `level` | Exactly `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `status` | An integer HTTP status from 100 through 599. |
| `latency_ms` | A finite number from 0 through 86,400,000. |

Extra fields are ignored. Blank lines are ignored. Invalid nonblank lines remain visible through `invalid` and `invalid_lines`, even when filters are active. Physical line numbers start at 1.

## Filters and report

```text
moon run cmd/main <input.jsonl> [--service NAME] [--level DEBUG|INFO|WARN|ERROR]
  [--since YYYY-MM-DDTHH:MM:SSZ] [--until YYYY-MM-DDTHH:MM:SSZ]
  [--format text|json] [--max-error-rate PERCENT]
```

Time bounds are inclusive. Valid events excluded by filters increment `filtered`, not `invalid`. Counts, percentiles, and error rates use accepted events only. `errors` counts HTTP 5xx statuses; 4xx responses are not counted as server errors. `error_rate_pct = errors / accepted * 100`, with zero for an empty selection. The P50 and P95 calculations use the nearest-rank method on sorted latency values. Results are grouped by service and exact HTTP status; groups are sorted for stable output. Service names in text output are JSON-quoted so control characters cannot create false report lines. JSON output contains the same data as text output.

`--max-error-rate` compares the overall percentage after filtering. Exit codes are 0 for a successful report (even with invalid input lines), 1 when the input file cannot be read, 2 for a CLI or filter error, and 3 when the error-rate threshold is exceeded. A threshold failure still writes the report to standard output, allowing CI to archive it.

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

The tests cover calendar and schema validation, invalid-line accounting, filters, aggregation, percentile boundaries, empty input, and JSON serialization. See [`examples/requests.jsonl`](examples/requests.jsonl) for a reproducible demo. Licensed under Apache-2.0.
