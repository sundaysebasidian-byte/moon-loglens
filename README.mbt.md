# Moon LogLens

Moon LogLens provides reusable JSONL analysis in MoonBit. Version 0.2.0 adds a schema-independent streaming query library and CLI for application events, background jobs, build pipelines and measurements. Choose nested fields, combine typed filters, group on multiple dimensions, and compute count/sum/min/max/mean without retaining every event. The original HTTP analyzer remains available for error rates and exact latency percentiles.

Parsing, validation, filtering, aggregation, and reporting are implemented in MoonBit. The public `query` package uses only MoonBit core APIs and performs no file or network I/O; applications supply lines themselves. The native CLIs use [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async) for I/O. All example data is illustrative test data, not production telemetry.

## Reproduce on Linux or macOS

Linux and macOS are the recommended platforms. The validated compiler is
`moonc v0.10.14+7d59c7ec9`; CI installs that exact release and checks its version.
An existing installation of that release can be reused. If it is unavailable,
the [official versioned Unix installer](https://www.moonbitlang.com/updates/2024/05/27/weekly-05-27)
accepts the complete version as a positional argument:

```sh
# Optional installation into a fresh, isolated directory:
export MOON_HOME="$(mktemp -d)"
export PATH="$MOON_HOME/bin:$PATH"
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s 0.10.14+7d59c7ec9
```

With Git, Python 3 and the MoonBit native toolchain available, run:

```sh
git clone https://github.com/sundaysebasidian-byte/moon-loglens.git
cd moon-loglens
moon version --all
moon update
moon check --target native
moon build --target native
moon test --target native
python3 tests/cli_smoke.py
python3 tests/query_cli.py
moon run cmd/main examples/requests.jsonl
moon run cmd/query examples/jobs.jsonl examples/jobs.query.json
moon run cmd/query examples/builds.jsonl examples/builds.query.json
moon run cmd/query examples/sensors.jsonl examples/sensors.query.json
moon run examples/reuse
```

The public 0.2.0 baseline is commit `f2744fad8225b2276f1a41338ac428d312cd4d06`.
The [acceptance script](scripts/acceptance.py) in this repository runs these checks plus the
external registry consumer and host input-boundary suite, and records evidence.
Current Windows kernel execution is unverified; the historical Windows result
and macOS input-boundary simulation below do not establish current Windows support.

## Schema-independent queries

Use the validated toolchain above, resolve dependencies with `moon update`, then run:

```sh
moon run cmd/query examples/jobs.jsonl examples/jobs.query.json
moon run cmd/query examples/builds.jsonl examples/builds.query.json
moon run cmd/query examples/sensors.jsonl examples/sensors.query.json
moon run examples/reuse
```

These examples exercise different schemas: job queues/outcomes and retry counts; build stages/runner operating systems and artifact sizes; sensor sites/devices and negative temperatures. None requires HTTP fields or timestamps. For jobs, three production events are accepted and one staging event filtered; the successful mail group has count 2, elapsed sum 40 and mean 20. Builds report compile sum 30 seconds; sensors report freezer mean -19 Celsius.

A query is a JSON file, for example:

```json
{
  "group_by": ["/task/queue", "/outcome"],
  "metrics": ["/elapsed_ms", "/attempts"],
  "where": [{"path": "/env", "op": "eq", "value": "production"}],
  "max_groups": 10000
}
```

- Field paths use JSON Pointer **string form**: `/task/queue` selects a nested field, `/readings/0/celsius` selects an array element, `~1` escapes `/`, and `~0` escapes `~`. The empty path selects the entire JSON value; URI-fragment pointers are not supported. A key literally named `a.b` is selected with `/a.b`.
- `group_by` and `metrics` default to empty arrays, but at least one must be nonempty. With no grouping, metrics are aggregated globally. With no metrics, groups provide counts only. Group fields must be present JSON scalars (including explicit null); metrics must be present finite numbers. Missing or wrongly typed selected fields make a line invalid, **before filtering**. Unselected fields are ignored.
- `where` is an AND list. `eq`/`ne` compare typed scalars; `gt`/`gte`/`lt`/`lte` compare numbers. Missing or non-scalar predicate fields never match, even `ne`. Explicit null differs from a missing field. Unknown configuration keys, invalid operators, duplicate paths and malformed pointers are rejected.
- Each field array and predicate list is limited to 64 entries. `max_groups` defaults to 10,000 and accepts integers 1–1,000,000. Exceeding it or overflowing a metric sum fails explicitly; no partial CLI report is emitted. Invalid-line diagnostics retain the first 100 physical line numbers and indicate truncation.

Output is JSON with physical `lines`, `accepted`, `filtered`, `invalid`, `invalid_lines`, `invalid_lines_truncated`, `group_by`, `metric_fields` and `groups`. Each group contains `key`, `count` and `metrics` arrays in the same order as the configured fields. Metrics contain `sum`, `min`, `max`, `mean`. Groups sort by canonical JSON key; strings, numbers, booleans and null remain distinct. Blank lines affect physical line numbers only. No matches produces an empty group array.

```sh
moon run cmd/query events.jsonl query.json --fail-on-invalid --min-events 1
# POSIX stdin pipeline (the '-' selects stdin):
cat examples/jobs.jsonl | moon run cmd/query - examples/jobs.query.json
```

The CLI consumes UTF-8 lines until EOF, including a final line without a newline, and accepts CRLF. It retains groups and metric summaries, not all events. Memory scales with the largest line plus group keys and metric count, not total event count; a single enormous line or an oversized query file can still use substantial memory. It is a batch stream processor, not a continuously updating dashboard. Numeric computation uses IEEE-754 doubles, so floating-point rounding applies and integers above 2^53 may lose precision: use **strings for identifiers**, not large numeric IDs. It does not parse arbitrary plain-text/CSV logs or perform timezone normalization.

Save input and query files as **UTF-8 without a BOM**. UTF-16 and legacy encoded
bytes are rejected as input errors. A UTF-8 BOM is not stripped: it makes the
first event invalid, or makes a query configuration fail to parse. Check the
encoding selected by your Windows editor or shell before running the CLI.

Query CLI exit codes: 0 success, 1 file/UTF-8 input error, 2 argument/query error, 4 invalid rows under `--fail-on-invalid`, 5 too few accepted events, 8 aggregation/line-count limit. Quality-gate failures (4/5) still print the completed report; read/limit failures do not. Invalid-row gating precedes minimum count. Group values are intentionally included in output; do not select private fields as group keys. Raw invalid lines and unrelated event fields are never echoed.

## Reuse from another MoonBit project

Add `sundaysebasidian-byte/moon-loglens@0.2.0` to your module dependencies, then import the package in `moon.pkg`:

```text
// moon.mod in your independent module
name = "loglens-acceptance/consumer"
preferred_target = "native"
import {
  "sundaysebasidian-byte/moon-loglens@0.2.0",
}
```

```text
import {
  "sundaysebasidian-byte/moon-loglens/query" @lens,
}
```

The [complete runnable embedding example](examples/reuse/main.mbt) uses `@lens.Query::parse`, `@lens.Accumulator::new`, `push_line` and `report`. It performs no filesystem access. It demonstrates how another tool can aggregate events received from its own file reader, service or queue without launching our CLI. Query plans are opaque; reports are independent snapshots, and modifying a returned array cannot corrupt later accumulation. Invalid data increments diagnostics; `QueryError::LimitExceeded` leaves the accumulator at its last complete state so a caller can decide how to recover.

For a complete **external module** using the published 0.2.0 package, copy the
[consumer fixture](tests/registry_consumer/main.mbt) outside this checkout:

```sh
consumer_dir="$(mktemp -d)"
cp tests/registry_consumer/moon.mod tests/registry_consumer/moon.pkg tests/registry_consumer/main.mbt "$consumer_dir/"
moon -C "$consumer_dir" update
moon -C "$consumer_dir" check --target native
moon -C "$consumer_dir" run .
# Automated independent-module run with a complete JSON result assertion:
python3 scripts/acceptance.py --consumer-only
```

Its two non-HTTP build events produce count 2, sum 30 and mean 15. Dependencies
resolve from Mooncakes, with no local-path override. `examples/reuse` alone is
a same-module embedding example and does not prove this downstream resolution.

### Related ecosystem tools

[MoonJQ](https://mooncakes.io/docs/bobzhang/moonjq) already provides a general jq-compatible interpreter, including NDJSON evaluation. [MoonJSONPath](https://mooncakes.io/docs/Freesia666/moonjsonpath) provides JSON navigation and transformation. There is overlap in selection and filtering; this project does not claim those capabilities are absent from MoonBit. LogLens focuses on an incremental aggregate/report contract: separate accepted/filtered/invalid counts, physical-line diagnostics, controlled group cardinality, atomic aggregate failure and process-level quality gates. It offers a fixed configuration and reusable accumulator, not a new general-purpose expression language. Whether that distinct scope merits competition support is for the organizers to evaluate.

## HTTP analyzer quick start

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

On Windows PowerShell, install MoonBit, add `moon` to `PATH`, and use the same `moon` commands. If Python is installed, run the integration checks with `py tests\cli_smoke.py`. The project owner ran the guarded check/build/test and CLI smoke workflow on Windows against commit `91a848e` on 2026-09-24; the shared output shows all five Python integration tests passing and the expected sample report. Later changes have been checked on macOS and by the repository's Linux CI; the latest Windows result applies to the earlier commit only.

Sample text output starts with:

```text
accepted=4 filtered=0 invalid=1 errors=1 error_rate_pct=25 p50_ms=20 p95_ms=150
invalid_lines=5
service="api" requests=3 errors=1 error_rate_pct=33.333333333333336 p50_ms=20 p95_ms=150
```

The example deliberately contains one malformed line. A nonzero `invalid` count does not automatically fail a normal report; review `invalid_lines` and fix the source data as appropriate. The final command above exits with code 7 because the `api` service exceeds the 30% service error-rate limit. The `--fail-on-invalid` example exits with code 4 because of the malformed line. Both commands still print their reports.

## HTTP input contract

The input is UTF-8 JSON Lines: one JSON object per nonblank line. Every event requires the following fields:

| Field | Type and rule |
| --- | --- |
| `timestamp` | A valid UTC timestamp in whole seconds (`2026-09-24T03:00:00Z`) or exactly three fractional digits (`2026-09-24T03:00:00.250Z`); no offsets or leap seconds. |
| `service` | A nonblank string. |
| `level` | Exactly `DEBUG`, `INFO`, `WARN`, or `ERROR`. |
| `status` | An integer HTTP status from 100 through 599. |
| `latency_ms` | A finite number from 0 through 86,400,000. |

Extra fields are ignored. Blank lines are ignored. Invalid nonblank lines remain visible through `invalid` and `invalid_lines`, even when filters are active. Physical line numbers start at 1.

## HTTP filters and report

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

## HTTP scope and limits

The HTTP analyzer (`cmd/main`) reads the whole file and keeps selected events in memory to compute exact percentiles. It is intended for bounded local logs and CI artifacts. Use `cmd/query` for line-by-line grouped summaries. Neither mode normalizes timezone offsets, infers missing fields, redacts arbitrary source files or sends data over the network. HTTP `--max-error-rate` checks only accepted events.

## Development

For a serial acceptance run with command exit codes, toolchain/platform details,
source hashes, and an independently resolved Mooncakes 0.2.0 consumer:

```sh
python3 scripts/acceptance.py
```

This requires the existing MoonBit native toolchain, Python 3, Git and access to
the official Mooncakes registry. It installs no tools. Evidence is written to a
new directory next to the checkout; `--output /path/outside/checkout` selects a
different new directory. Set `MOON_BIN` if `moon` is not on `PATH`. The consumer
fixture is copied into a temporary module outside the repository, with an exact
registry version and no local-path override. Its complete report is asserted;
the three non-HTTP examples also have explicit aggregate assertions. Failures
stop the run and remain recorded in `manifest.json`. See the
[中文验收 walkthrough and requirement matrix](docs/acceptance.zh-CN.md) and
[AI assistance, design decisions and licenses](docs/design-and-attribution.zh-CN.md).

```sh
moon check --target native
moon test --target native
moon build --target native
moon info
moon fmt
python3 tests/cli_smoke.py
python3 tests/query_cli.py
python3 tests/platform_inputs.py
```

`platform_inputs.py` exercises real host CLI processes with Unicode/space paths,
CRLF, encoding boundaries and exit codes. A macOS run is input-boundary evidence;
it does not emulate Windows paths, a Windows kernel, or a Wine runtime.

The MoonBit suite includes the original 10 HTTP tests and 12 public query API tests. Two Python standard-library CLI suites (8 tests each) exercise both real native CLIs, three non-HTTP schemas, stdin/file parity, encoding errors, 20,000 valid records, limits, exit codes and the embedding example. The additional host input-boundary suite has 5 tests. GitHub Actions invokes the acceptance script on Linux with the pinned compiler and preserves its evidence. Check the workflow run for the exact commit being evaluated; historical CI success applies only to its recorded SHA. See [the version 0.2 changes](CHANGELOG.md) for scope and [the reusable API](query/pkg.generated.mbti) for exported types. The new query code is original; no third-party implementation was transplanted. Licensed under Apache-2.0; dependency APIs and MoonBit core provide JSON, containers and I/O.
