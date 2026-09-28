///|
pub(all) suberror QueryError {
  InvalidQuery(String)
  LimitExceeded(String)
} derive(@debug.Debug)

///|
pub extend QueryError with @debug.Debug::{to_repr}

///|
priv struct Field {
  path : String
  tokens : Array[String]
}

///|
priv struct Predicate {
  field : Field
  op : String
  value : Json
}

///|
/// Validated, immutable query plan. Create it with `Query::parse`.
pub struct Query {
  priv groups : Array[Field]
  priv metrics : Array[Field]
  priv predicates : Array[Predicate]
  priv max_groups : Int
}

///|
fn finite(n : Double) -> Bool {
  !n.is_nan() && !n.is_inf()
}

///|
fn scalar(value : Json) -> Json? {
  match value {
    Json::Null | Json::True | Json::False | Json::String(_) => Some(value)
    Json::Number(n, ..) =>
      if finite(n) {
        Some((if n == 0.0 { 0.0 } else { n }).to_json())
      } else {
        None
      }
    _ => None
  }
}

///|
fn field(path : String) -> Field raise QueryError {
  if path == "" {
    return { path, tokens: [], }
  }
  if !path.has_prefix("/") {
    raise InvalidQuery(
      "field paths must be JSON Pointer strings beginning with /",
    )
  }
  let tokens = []
  for part in path[1:].split("/") {
    let s = part.to_owned()
    let mut i = 0
    while i < s.length() {
      if s.unsafe_get(i).to_int() == 126 {
        if i + 1 >= s.length() ||
          (
            s.unsafe_get(i + 1).to_int() != 48 &&
            s.unsafe_get(i + 1).to_int() != 49
          ) {
          raise InvalidQuery("invalid JSON Pointer escape; use ~0 or ~1")
        }
        i += 1
      }
      i += 1
    }
    tokens.push(s.replace_all(old="~1", new="/").replace_all(old="~0", new="~"))
  }
  { path, tokens, }
}

///|
fn fields(value : Json?) -> Array[Field] raise QueryError {
  if value is None {
    return []
  }
  guard value is Some(Json::Array(items)) else {
    raise InvalidQuery(
      "group_by and metrics must be arrays of JSON Pointer strings",
    )
  }
  if items.length() > 64 {
    raise InvalidQuery("at most 64 fields per array")
  }
  let result : Array[Field] = []
  for item in items {
    guard item is Json::String(path) else {
      raise InvalidQuery("field paths must be strings")
    }
    if result.any(fn(f) { f.path == path }) {
      raise InvalidQuery("duplicate field path")
    }
    result.push(field(path))
  }
  result
}

///|
/// Parse strict query JSON. Unknown keys and malformed paths are errors.
/// At least one of group_by or metrics must be nonempty; where is an AND list.
pub fn Query::parse(source : String) -> Query raise QueryError {
  let parsed = @json.parse(source) catch {
    _ => raise InvalidQuery("query is not valid JSON")
  }
  guard parsed is Json::Object(obj) else {
    raise InvalidQuery("query must be an object")
  }
  for key, _ in obj {
    if key != "group_by" &&
      key != "metrics" &&
      key != "where" &&
      key != "max_groups" {
      raise InvalidQuery("unknown query key")
    }
  }
  let groups = fields(obj.get("group_by"))
  let metrics = fields(obj.get("metrics"))
  if groups.is_empty() && metrics.is_empty() {
    raise InvalidQuery("provide at least one group_by or metrics field")
  }
  let mut max_groups = 10000
  if obj.get("max_groups") is Some(value) {
    guard value is Json::Number(n, ..) else {
      raise InvalidQuery(
        "max_groups must be a positive integer at most 1000000",
      )
    }
    if !finite(n) || n < 1.0 || n > 1000000.0 || n != n.to_int().to_double() {
      raise InvalidQuery(
        "max_groups must be a positive integer at most 1000000",
      )
    }
    max_groups = n.to_int()
  }
  let predicates = []
  if obj.get("where") is Some(value) {
    guard value is Json::Array(items) else {
      raise InvalidQuery("where must be an array")
    }
    if items.length() > 64 {
      raise InvalidQuery("at most 64 predicates")
    }
    for item in items {
      guard item is Json::Object(p) else {
        raise InvalidQuery("predicate must be an object")
      }
      for key, _ in p {
        if key != "path" && key != "op" && key != "value" {
          raise InvalidQuery("unknown predicate key")
        }
      }
      guard (p.get("path"), p.get("op"), p.get("value"))
        is (Some(Json::String(path)), Some(Json::String(op)), Some(v)) else {
        raise InvalidQuery("predicate requires path, op and value")
      }
      guard scalar(v) is Some(value) else {
        raise InvalidQuery("predicate value must be a finite scalar")
      }
      if op != "eq" &&
        op != "ne" &&
        op != "gt" &&
        op != "gte" &&
        op != "lt" &&
        op != "lte" {
        raise InvalidQuery("supported operators: eq, ne, gt, gte, lt, lte")
      }
      if op != "eq" && op != "ne" && !(value is Json::Number(_, ..)) {
        raise InvalidQuery("ordered comparisons require a numeric value")
      }
      predicates.push({ field: field(path), op, value, })
    }
  }
  { groups, metrics, predicates, max_groups, }
}

///|
fn lookup(value : Json, f : Field) -> Json? {
  let mut current = value
  for token in f.tokens {
    match current {
      Json::Object(obj) => {
        guard obj.get(token) is Some(next) else { return None }
        current = next
      }
      Json::Array(items) => {
        if token == "" || (token.length() > 1 && token.has_prefix("0")) {
          return None
        }
        let mut index = 0
        for i in 0..<token.length() {
          let digit = token.unsafe_get(i).to_int() - 48
          if digit < 0 || digit > 9 || index > (2147483647 - digit) / 10 {
            return None
          }
          index = index * 10 + digit
        }
        if index >= items.length() {
          return None
        }
        current = items[index]
      }
      _ => return None
    }
  }
  Some(current)
}

///|
fn matches(value : Json, p : Predicate) -> Bool {
  guard lookup(value, p.field) is Some(raw) else { return false }
  guard scalar(raw) is Some(actual) else { return false }
  match p.op {
    "eq" => actual == p.value
    "ne" => actual != p.value
    _ => {
      guard (actual, p.value) is (Json::Number(a, ..), Json::Number(b, ..)) else {
        return false
      }
      match p.op {
        "gt" => a > b
        "gte" => a >= b
        "lt" => a < b
        "lte" => a <= b
        _ => false
      }
    }
  }
}

///|
pub struct MetricStats {
  sum : Double
  min : Double
  max : Double
  mean : Double
} derive(ToJson)

///|
pub extend MetricStats with ToJson::{to_json}

///|
pub struct GroupStats {
  key : Array[Json]
  count : Int
  metrics : Array[MetricStats]
} derive(ToJson)

///|
pub extend GroupStats with ToJson::{to_json}

///|
/// key and metrics arrays use the order of group_by and metric_fields.
pub struct Report {
  lines : Int
  accepted : Int
  filtered : Int
  invalid : Int
  invalid_lines : Array[Int]
  invalid_lines_truncated : Bool
  group_by : Array[String]
  metric_fields : Array[String]
  groups : Array[GroupStats]
} derive(ToJson)

///|
pub extend Report with ToJson::{to_json}

///|
pub struct Accumulator {
  priv query : Query
  priv mut lines : Int
  priv mut accepted : Int
  priv mut filtered : Int
  priv mut invalid : Int
  priv invalid_lines : Array[Int]
  priv groups : @hashmap.HashMap[String, GroupStats]
}

///|
pub fn Accumulator::new(query : Query) -> Accumulator {
  {
    query,
    lines: 0,
    accepted: 0,
    filtered: 0,
    invalid: 0,
    invalid_lines: [],
    groups: @hashmap.HashMap([]),
  }
}

///|
fn Accumulator::invalid_line(self : Accumulator) -> Unit {
  self.invalid += 1
  if self.invalid_lines.length() < 100 {
    self.invalid_lines.push(self.lines)
  }
}

///|
/// Feed one physical line without its LF delimiter (CR is allowed).
/// Blank lines count toward physical line numbers but not event counts.
/// Missing/non-scalar group fields and missing/non-finite metrics are invalid,
/// checked before filtering. Limit errors leave the accumulator unchanged.
pub fn Accumulator::push_line(
  self : Accumulator,
  line : String,
) -> Unit raise QueryError {
  if self.lines == 2147483647 {
    raise LimitExceeded("physical line count exceeded")
  }
  let next_line = self.lines + 1
  if line.trim().is_empty() {
    self.lines = next_line
    return
  }
  let parsed = Some(@json.parse(line)) catch { _ => None }
  guard parsed is Some(value) else {
    self.lines = next_line
    self.invalid_line()
    return
  }
  let key = []
  for f in self.query.groups {
    guard lookup(value, f) is Some(v) && scalar(v) is Some(v) else {
      self.lines = next_line
      self.invalid_line()
      return
    }
    key.push(v)
  }
  let numbers = []
  for f in self.query.metrics {
    guard lookup(value, f) is Some(Json::Number(n, ..)) && finite(n) else {
      self.lines = next_line
      self.invalid_line()
      return
    }
    numbers.push(n)
  }
  if !self.query.predicates.all(fn(p) { matches(value, p) }) {
    self.lines = next_line
    self.filtered += 1
    return
  }
  let encoded = key.to_json().stringify()
  let previous = self.groups.get(encoded)
  if previous is None && self.groups.length() >= self.query.max_groups {
    raise LimitExceeded("max_groups exceeded")
  }
  let count = match previous {
    Some(g) => g.count + 1
    None => 1
  }
  let metrics = []
  for i in 0..<numbers.length() {
    let n = numbers[i]
    let stats = match previous {
      Some(g) => {
        let old = g.metrics[i]
        let sum = old.sum + n
        if !finite(sum) {
          raise LimitExceeded("metric sum overflow")
        }
        {
          sum,
          min: if n < old.min {
            n
          } else {
            old.min
          },
          max: if n > old.max {
            n
          } else {
            old.max
          },
          mean: sum / count.to_double(),
        }
      }
      None => { sum: n, min: n, max: n, mean: n, }
    }
    metrics.push(stats)
  }
  self.groups.set(encoded, { key, count, metrics, })
  self.lines = next_line
  self.accepted += 1
}

///|
/// Independent snapshot, sorted by canonical JSON group key.
pub fn Accumulator::report(self : Accumulator) -> Report {
  let groups = self.groups
    .values()
    .map(fn(g) {
      { key: g.key.copy(), count: g.count, metrics: g.metrics.copy(), }
    })
    .collect()
  groups.sort_by(fn(a, b) {
    a.key.to_json().stringify()[:].lexical_compare(
      b.key.to_json().stringify()[:],
    )
  })
  {
    lines: self.lines,
    accepted: self.accepted,
    filtered: self.filtered,
    invalid: self.invalid,
    invalid_lines: self.invalid_lines.copy(),
    invalid_lines_truncated: self.invalid > self.invalid_lines.length(),
    group_by: self.query.groups.map(fn(f) { f.path }),
    metric_fields: self.query.metrics.map(fn(f) { f.path }),
    groups,
  }
}
