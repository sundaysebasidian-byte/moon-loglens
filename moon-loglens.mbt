///|
pub struct Config {
  service : String
  level : String
  status : Int
  since : String
  until : String
}

///|
pub fn Config::new(
  service? : String = "",
  level? : String = "",
  status? : Int = 0,
  since? : String = "",
  until? : String = "",
) -> Config {
  { service, level, status, since, until, }
}

///|
pub fn Config::validate(self : Config) -> String? {
  if self.level != "" &&
    self.level != "DEBUG" &&
    self.level != "INFO" &&
    self.level != "WARN" &&
    self.level != "ERROR" {
    return Some("--level must be DEBUG, INFO, WARN, or ERROR")
  }
  if self.status != 0 && (self.status < 100 || self.status > 599) {
    return Some("--status must be an HTTP status from 100 through 599")
  }
  if self.since != "" && !valid_timestamp(self.since) {
    return Some(
      "--since must be a valid UTC timestamp such as 2026-09-24T03:00:00Z",
    )
  }
  if self.until != "" && !valid_timestamp(self.until) {
    return Some(
      "--until must be a valid UTC timestamp such as 2026-09-24T03:00:00Z",
    )
  }
  if self.since != "" && self.until != "" && self.since > self.until {
    return Some("--since must be at or before --until")
  }
  None
}

///|
pub struct ServiceStats {
  name : String
  count : Int
  errors : Int
  error_rate_pct : Double
  p50_ms : Double
  p95_ms : Double
}

///|
pub struct StatusStats {
  service : String
  status : Int
  count : Int
  p50_ms : Double
  p95_ms : Double
}

///|
pub struct Report {
  accepted : Int
  filtered : Int
  invalid : Int
  invalid_lines : Array[Int]
  errors : Int
  error_rate_pct : Double
  services : Array[ServiceStats]
  statuses : Array[StatusStats]
}

///|
priv struct Entry {
  timestamp : String
  service : String
  level : String
  status : Int
  latency_ms : Double
}

///|
fn digit_at(s : String, i : Int) -> Int {
  let value = s.unsafe_get(i).to_int()
  if value >= 48 && value <= 57 {
    value - 48
  } else {
    -1
  }
}

///|
fn digits(s : String, start : Int, end : Int) -> Int {
  let mut value = 0
  for i in start..<end {
    let digit = digit_at(s, i)
    if digit < 0 {
      return -1
    }
    value = value * 10 + digit
  }
  value
}

///|
/// Accepts fixed-width UTC ISO 8601 seconds; lexical range filters are exact.
pub fn valid_timestamp(s : String) -> Bool {
  if s.length() != 20 ||
    s.unsafe_get(4).to_int() != 45 ||
    s.unsafe_get(7).to_int() != 45 ||
    s.unsafe_get(10).to_int() != 84 ||
    s.unsafe_get(13).to_int() != 58 ||
    s.unsafe_get(16).to_int() != 58 ||
    s.unsafe_get(19).to_int() != 90 {
    return false
  }
  let year = digits(s, 0, 4)
  let month = digits(s, 5, 7)
  let day = digits(s, 8, 10)
  let hour = digits(s, 11, 13)
  let minute = digits(s, 14, 16)
  let second = digits(s, 17, 19)
  if year < 1 ||
    month < 1 ||
    month > 12 ||
    hour < 0 ||
    hour > 23 ||
    minute < 0 ||
    minute > 59 ||
    second < 0 ||
    second > 59 {
    return false
  }
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let days = match month {
    2 => if leap { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
  day >= 1 && day <= days
}

///|
fn parse_entry(line : String) -> Entry? {
  let parsed = Some(@json.parse(line)) catch { _ => None }
  guard parsed is Some(Json::Object(fields)) else { return None }
  match
    (
      fields.get("timestamp"),
      fields.get("service"),
      fields.get("level"),
      fields.get("status"),
      fields.get("latency_ms"),
    ) {
    (
      Some(Json::String(timestamp)),
      Some(Json::String(service)),
      Some(Json::String(level)),
      Some(Json::Number(status, ..)),
      Some(Json::Number(latency_ms, ..)),
    ) => {
      if !valid_timestamp(timestamp) ||
        service.trim().is_empty() ||
        (
          level != "DEBUG" &&
          level != "INFO" &&
          level != "WARN" &&
          level != "ERROR"
        ) ||
        status < 100.0 ||
        status > 599.0 ||
        status != status.to_int().to_double() ||
        latency_ms < 0.0 ||
        latency_ms > 86400000.0 ||
        latency_ms.is_nan() {
        return None
      }
      Some({ timestamp, service, level, status: status.to_int(), latency_ms, })
    }
    _ => None
  }
}

///|
fn percentile(values : Array[Double], percentile : Int) -> Double {
  if values.is_empty() {
    return 0.0
  }
  values.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  let index = ((values.length() * percentile + 99) / 100 - 1).max(0)
  values[index]
}

///|
fn rate(errors : Int, count : Int) -> Double {
  if count == 0 {
    0.0
  } else {
    errors.to_double() * 100.0 / count.to_double()
  }
}

///|
/// Invalid nonblank lines are reported by physical line number without
/// including raw content, so a report does not expose log payloads.
pub fn analyze(content : String, config? : Config = Config::new()) -> Report {
  let entries : Array[Entry] = []
  let invalid_lines : Array[Int] = []
  let mut filtered = 0
  for index, raw_line in content.split("\n") {
    let line = raw_line.trim().to_owned()
    if line.is_empty() {
      continue
    }
    match parse_entry(line) {
      None => invalid_lines.push(index + 1)
      Some(entry) =>
        if (config.service != "" && entry.service != config.service) ||
          (config.level != "" && entry.level != config.level) ||
          (config.status != 0 && entry.status != config.status) ||
          (config.since != "" && entry.timestamp < config.since) ||
          (config.until != "" && entry.timestamp > config.until) {
          filtered += 1
        } else {
          entries.push(entry)
        }
    }
  }
  let service_names : Array[String] = []
  let service_latencies : Array[Array[Double]] = []
  let service_errors : Array[Int] = []
  let group_services : Array[String] = []
  let group_statuses : Array[Int] = []
  let group_latencies : Array[Array[Double]] = []
  let mut errors = 0
  for entry in entries {
    let mut service_index = -1
    for i, name in service_names {
      if name == entry.service {
        service_index = i
        break
      }
    }
    if service_index == -1 {
      service_index = service_names.length()
      service_names.push(entry.service)
      service_latencies.push([])
      service_errors.push(0)
    }
    service_latencies[service_index].push(entry.latency_ms)
    if entry.status >= 500 {
      service_errors[service_index] += 1
      errors += 1
    }
    let mut group_index = -1
    for i, service in group_services {
      if service == entry.service && group_statuses[i] == entry.status {
        group_index = i
        break
      }
    }
    if group_index == -1 {
      group_index = group_services.length()
      group_services.push(entry.service)
      group_statuses.push(entry.status)
      group_latencies.push([])
    }
    group_latencies[group_index].push(entry.latency_ms)
  }
  let services : Array[ServiceStats] = []
  for i, name in service_names {
    let count = service_latencies[i].length()
    let service_error_count = service_errors[i]
    services.push({
      name,
      count,
      errors: service_error_count,
      error_rate_pct: rate(service_error_count, count),
      p50_ms: percentile(service_latencies[i].copy(), 50),
      p95_ms: percentile(service_latencies[i].copy(), 95),
    })
  }
  services.sort_by(fn(a, b) { a.name[:].lexical_compare(b.name[:]) })
  let statuses : Array[StatusStats] = []
  for i, service in group_services {
    let latencies = group_latencies[i]
    statuses.push({
      service,
      status: group_statuses[i],
      count: latencies.length(),
      p50_ms: percentile(latencies.copy(), 50),
      p95_ms: percentile(latencies.copy(), 95),
    })
  }
  statuses.sort_by(fn(a, b) {
    let order = a.service[:].lexical_compare(b.service[:])
    if order != 0 {
      order
    } else {
      a.status.compare(b.status)
    }
  })
  {
    accepted: entries.length(),
    filtered,
    invalid: invalid_lines.length(),
    invalid_lines,
    errors,
    error_rate_pct: rate(errors, entries.length()),
    services,
    statuses,
  }
}

///|
pub fn Report::to_text(self : Report) -> String {
  let mut output = "accepted=\{self.accepted} filtered=\{self.filtered} invalid=\{self.invalid} errors=\{self.errors} error_rate_pct=\{self.error_rate_pct}\n"
  if !self.invalid_lines.is_empty() {
    output += "invalid_lines="
    for i, line in self.invalid_lines {
      if i > 0 {
        output += ","
      }
      output += line.to_string()
    }
    output += "\n"
  }
  for service in self.services {
    let name = Json::string(service.name).stringify()
    output += "service=\{name} requests=\{service.count} errors=\{service.errors} error_rate_pct=\{service.error_rate_pct} p50_ms=\{service.p50_ms} p95_ms=\{service.p95_ms}\n"
  }
  for group in self.statuses {
    let name = Json::string(group.service).stringify()
    output += "service=\{name} status=\{group.status} requests=\{group.count} p50_ms=\{group.p50_ms} p95_ms=\{group.p95_ms}\n"
  }
  output
}

///|
pub fn Report::to_json(self : Report) -> Json {
  let service_values : Array[Json] = []
  for service in self.services {
    service_values.push({
      "name": Json::string(service.name),
      "count": Json::number(service.count.to_double()),
      "errors": Json::number(service.errors.to_double()),
      "error_rate_pct": Json::number(service.error_rate_pct),
      "p50_ms": Json::number(service.p50_ms),
      "p95_ms": Json::number(service.p95_ms),
    })
  }
  let status_values : Array[Json] = []
  for group in self.statuses {
    status_values.push({
      "service": Json::string(group.service),
      "status": Json::number(group.status.to_double()),
      "count": Json::number(group.count.to_double()),
      "p50_ms": Json::number(group.p50_ms),
      "p95_ms": Json::number(group.p95_ms),
    })
  }
  let bad_lines : Array[Json] = []
  for line in self.invalid_lines {
    bad_lines.push(Json::number(line.to_double()))
  }
  {
    "accepted": Json::number(self.accepted.to_double()),
    "filtered": Json::number(self.filtered.to_double()),
    "invalid": Json::number(self.invalid.to_double()),
    "invalid_lines": Json::array(bad_lines),
    "errors": Json::number(self.errors.to_double()),
    "error_rate_pct": Json::number(self.error_rate_pct),
    "services": Json::array(service_values),
    "statuses": Json::array(status_values),
  }
}
