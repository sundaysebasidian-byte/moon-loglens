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
  if self.since != "" &&
    self.until != "" &&
    timestamp_sort_key(self.since) > timestamp_sort_key(self.until) {
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
  p50_ms : Double
  p95_ms : Double
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
/// Accepts fixed-width UTC ISO 8601 seconds or milliseconds.
pub fn valid_timestamp(s : String) -> Bool {
  if (s.length() != 20 && s.length() != 24) ||
    s.unsafe_get(4).to_int() != 45 ||
    s.unsafe_get(7).to_int() != 45 ||
    s.unsafe_get(10).to_int() != 84 ||
    s.unsafe_get(13).to_int() != 58 ||
    s.unsafe_get(16).to_int() != 58 {
    return false
  }
  if s.length() == 20 {
    if s.unsafe_get(19).to_int() != 90 {
      return false
    }
  } else if s.unsafe_get(19).to_int() != 46 ||
    s.unsafe_get(23).to_int() != 90 ||
    digits(s, 20, 23) < 0 {
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
/// Normalizing whole seconds to .000 makes lexical time bounds exact.
fn timestamp_sort_key(s : String) -> String {
  if s.length() == 20 {
    s[:19].to_owned() + ".000Z"
  } else {
    s
  }
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
      Some({
        timestamp: timestamp_sort_key(timestamp),
        service,
        level,
        status: status.to_int(),
        latency_ms,
      })
    }
    _ => None
  }
}

///|
/// Nearest-rank percentile of values that are already sorted ascending.
fn nearest_rank(sorted : Array[Double], pct : Int) -> Double {
  let n = sorted.length()
  if n == 0 {
    return 0.0
  }
  // ceil(n * pct / 100), split so that very large inputs cannot overflow Int.
  let rank = n / 100 * pct + (n % 100 * pct + 99) / 100
  sorted[(rank - 1).max(0)]
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
priv struct ServiceGroup {
  name : String
  latencies : Array[Double]
  mut errors : Int
  status_indices : @hashmap.HashMap[Int, Int]
}

///|
priv struct StatusGroup {
  service : String
  status : Int
  latencies : Array[Double]
}

///|
/// Invalid nonblank lines are reported by physical line number without
/// including raw content, so a report does not expose log payloads.
/// Accepted events are aggregated as they are read; only latencies are kept.
pub fn analyze(content : String, config? : Config = Config::new()) -> Report {
  let invalid_lines : Array[Int] = []
  let mut filtered = 0
  let since = if config.since == "" {
    ""
  } else {
    timestamp_sort_key(config.since)
  }
  let until = if config.until == "" {
    ""
  } else {
    timestamp_sort_key(config.until)
  }
  let service_indices : @hashmap.HashMap[String, Int] = HashMap([])
  let service_groups : Array[ServiceGroup] = []
  let status_groups : Array[StatusGroup] = []
  let all_latencies : Array[Double] = []
  let mut errors = 0
  // Editors on Windows often save UTF-8 with a byte order mark, which would
  // otherwise make the first line invalid JSON.
  let content = if content.has_prefix("\u{FEFF}") {
    content[1:].to_owned()
  } else {
    content
  }
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
          (since != "" && entry.timestamp < since) ||
          (until != "" && entry.timestamp > until) {
          filtered += 1
        } else {
          all_latencies.push(entry.latency_ms)
          let service = match service_indices.get(entry.service) {
            Some(existing) => service_groups[existing]
            None => {
              let status_indices : @hashmap.HashMap[Int, Int] = HashMap([])
              let group : ServiceGroup = {
                name: entry.service,
                latencies: [],
                errors: 0,
                status_indices,
              }
              service_indices.set(entry.service, service_groups.length())
              service_groups.push(group)
              group
            }
          }
          service.latencies.push(entry.latency_ms)
          if entry.status >= 500 {
            service.errors += 1
            errors += 1
          }
          let status_group = match service.status_indices.get(entry.status) {
            Some(existing) => status_groups[existing]
            None => {
              let group : StatusGroup = {
                service: entry.service,
                status: entry.status,
                latencies: [],
              }
              service.status_indices.set(entry.status, status_groups.length())
              status_groups.push(group)
              group
            }
          }
          status_group.latencies.push(entry.latency_ms)
        }
    }
  }
  let services : Array[ServiceStats] = []
  for group in service_groups {
    let latencies = group.latencies
    latencies.sort()
    services.push({
      name: group.name,
      count: latencies.length(),
      errors: group.errors,
      error_rate_pct: rate(group.errors, latencies.length()),
      p50_ms: nearest_rank(latencies, 50),
      p95_ms: nearest_rank(latencies, 95),
    })
  }
  services.sort_by(fn(a, b) { a.name[:].lexical_compare(b.name[:]) })
  let statuses : Array[StatusStats] = []
  for group in status_groups {
    let latencies = group.latencies
    latencies.sort()
    statuses.push({
      service: group.service,
      status: group.status,
      count: latencies.length(),
      p50_ms: nearest_rank(latencies, 50),
      p95_ms: nearest_rank(latencies, 95),
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
  all_latencies.sort()
  {
    accepted: all_latencies.length(),
    filtered,
    invalid: invalid_lines.length(),
    invalid_lines,
    errors,
    error_rate_pct: rate(errors, all_latencies.length()),
    p50_ms: nearest_rank(all_latencies, 50),
    p95_ms: nearest_rank(all_latencies, 95),
    services,
    statuses,
  }
}

///|
pub fn Report::to_text(self : Report) -> String {
  let output = StringBuilder()
  output.write_string(
    "accepted=\{self.accepted} filtered=\{self.filtered} invalid=\{self.invalid} errors=\{self.errors} error_rate_pct=\{self.error_rate_pct} p50_ms=\{self.p50_ms} p95_ms=\{self.p95_ms}\n",
  )
  if !self.invalid_lines.is_empty() {
    output.write_string("invalid_lines=")
    for i, line in self.invalid_lines {
      if i > 0 {
        output.write_char(',')
      }
      output.write_string(line.to_string())
    }
    output.write_char('\n')
  }
  for service in self.services {
    let name = Json::string(service.name).stringify()
    output.write_string(
      "service=\{name} requests=\{service.count} errors=\{service.errors} error_rate_pct=\{service.error_rate_pct} p50_ms=\{service.p50_ms} p95_ms=\{service.p95_ms}\n",
    )
  }
  for group in self.statuses {
    let name = Json::string(group.service).stringify()
    output.write_string(
      "service=\{name} status=\{group.status} requests=\{group.count} p50_ms=\{group.p50_ms} p95_ms=\{group.p95_ms}\n",
    )
  }
  output.to_string()
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
    "p50_ms": Json::number(self.p50_ms),
    "p95_ms": Json::number(self.p95_ms),
    "services": Json::array(service_values),
    "statuses": Json::array(status_values),
  }
}
