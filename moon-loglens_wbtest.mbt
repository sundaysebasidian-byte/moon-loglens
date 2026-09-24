///|
fn event(
  timestamp : String,
  service : String,
  level : String,
  status : String,
  latency : String,
) -> String {
  "{\"timestamp\":\"\{timestamp}\",\"service\":\"\{service}\",\"level\":\"\{level}\",\"status\":\{status},\"latency_ms\":\{latency}}"
}

///|
test "calendar validation rejects impossible UTC timestamps" {
  assert_true(valid_timestamp("2024-02-29T23:59:59Z"))
  assert_true(!valid_timestamp("2026-02-29T00:00:00Z"))
  assert_true(!valid_timestamp("2026-13-01T00:00:00Z"))
  assert_true(!valid_timestamp("2026-01-01T24:00:00Z"))
  assert_true(!valid_timestamp("2026-01-01T00:00:60Z"))
  assert_true(!valid_timestamp("2026-01-01T00:00:00+00:00"))
}

///|
test "schema errors are counted by line and cannot disappear under a filter" {
  let input = event("2026-09-24T03:00:00Z", "api", "INFO", "200", "12") +
    "\n" +
    "not-json\n" +
    event("2026-09-24T03:00:01Z", "worker", "ERROR", "503", "20") +
    "\n" +
    event("2026-02-29T03:00:02Z", "api", "INFO", "200", "30") +
    "\n" +
    event("2026-09-24T03:00:03Z", "api", "INFO", "200.5", "40") +
    "\n" +
    event("2026-09-24T03:00:04Z", "api", "INFO", "200", "-1") +
    "\n"
  let report = analyze(input, config=Config::new(service="api"))
  assert_eq(report.accepted, 1)
  assert_eq(report.filtered, 1)
  assert_eq(report.invalid, 4)
  assert_eq(report.invalid_lines, [2, 4, 5, 6])
  assert_eq(report.errors, 0)
}

///|
test "inclusive UTC and level filters select only eligible valid events" {
  let input = event("2026-09-24T03:00:00Z", "api", "INFO", "200", "12") +
    "\n" +
    event("2026-09-24T03:00:01Z", "api", "ERROR", "503", "150") +
    "\n" +
    event("2026-09-24T03:00:02Z", "api", "ERROR", "504", "170")
  let report = analyze(
    input,
    config=Config::new(
      level="ERROR",
      since="2026-09-24T03:00:01Z",
      until="2026-09-24T03:00:01Z",
    ),
  )
  assert_eq(report.accepted, 1)
  assert_eq(report.filtered, 2)
  assert_eq(report.errors, 1)
  assert_eq(report.error_rate_pct, 100.0)
  assert_eq(report.services[0].p50_ms, 150.0)
}

///|
test "service and status aggregation uses nearest-rank p95 and stable order" {
  let mut input = ""
  for i in 1..<=20 {
    input += event("2026-09-24T03:00:00Z", "zeta", "INFO", "200", i.to_string()) +
      "\n"
  }
  input += event("2026-09-24T03:00:01Z", "alpha", "ERROR", "500", "40")
  let report = analyze(input)
  assert_eq(report.accepted, 21)
  assert_eq(report.errors, 1)
  assert_eq(report.services.length(), 2)
  assert_eq(report.services[0].name, "alpha")
  assert_eq(report.services[1].name, "zeta")
  assert_eq(report.services[1].p50_ms, 10.0)
  assert_eq(report.services[1].p95_ms, 19.0)
  assert_eq(report.statuses[0].status, 500)
  assert_eq(report.statuses[1].status, 200)
}

///|
test "empty analysis and JSON serialization remain valid" {
  let empty = analyze("\n  \n")
  assert_eq(empty.accepted, 0)
  assert_eq(empty.error_rate_pct, 0.0)
  assert_eq(empty.services.length(), 0)
  let report = analyze(
    event("2026-09-24T03:00:00Z", "api", "INFO", "200", "1.5"),
  )
  let value = report.to_json()
  assert_eq(@json.parse(value.stringify()), value)
  assert_eq(report.services[0].p50_ms, 1.5)
}

///|
test "invalid filters are rejected before analysis" {
  assert_true(Config::new(level="TRACE").validate() is Some(_))
  assert_true(Config::new(since="yesterday").validate() is Some(_))
  assert_true(
    Config::new(since="2026-09-25T00:00:00Z", until="2026-09-24T00:00:00Z").validate()
    is Some(_),
  )
  assert_true(Config::new().validate() is None)
}
