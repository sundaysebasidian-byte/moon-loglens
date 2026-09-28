///|
fn run_query(config : String, lines : Array[String]) -> @query.Report raise {
  let acc = @query.Accumulator::new(@query.Query::parse(config))
  for line in lines {
    acc.push_line(line)
  }
  acc.report()
}

///|
test "public API groups background jobs without HTTP schema" {
  let report = run_query(
    "{\"group_by\":[\"/queue\",\"/outcome\"],\"metrics\":[\"/elapsed\",\"/attempts\"]}",
    [
      "{\"queue\":\"mail\",\"outcome\":\"ok\",\"elapsed\":10,\"attempts\":1}", "{\"queue\":\"mail\",\"outcome\":\"ok\",\"elapsed\":30,\"attempts\":3}",
      "{\"queue\":\"mail\",\"outcome\":\"failed\",\"elapsed\":50,\"attempts\":4}",
    ],
  )
  assert_eq(report.accepted, 3)
  assert_eq(report.groups.length(), 2)
  let ok = report.groups[1]
  assert_eq(ok.count, 2)
  assert_eq(ok.metrics[0].sum, 40.0)
  assert_eq(ok.metrics[0].mean, 20.0)
  assert_eq(ok.metrics[0].min, 10.0)
  assert_eq(ok.metrics[0].max, 30.0)
  assert_eq(ok.metrics[1].sum, 4.0)
}

///|
test "nested objects arrays and escaped pointer tokens" {
  let report = run_query(
    "{\"group_by\":[\"/meta/a~1b/~0kind\",\"/\"],\"metrics\":[\"/readings/0/value\"]}",
    [
      "{\"meta\":{\"a/b\":{\"~kind\":\"温度🌡\"}},\"\":true,\"readings\":[{\"value\":-12.5}]}",
    ],
  )
  assert_eq(report.accepted, 1)
  assert_eq(report.groups[0].key, ["温度🌡".to_json(), true.to_json()])
  assert_eq(report.groups[0].metrics[0].min, -12.5)
}

///|
test "root pointer supports scalar numeric measurement streams" {
  let report = run_query("{\"metrics\":[\"\"]}", ["-3", "5", "10"])
  assert_eq(report.groups.length(), 1)
  assert_eq(report.groups[0].metrics[0].sum, 12.0)
  assert_eq(report.groups[0].metrics[0].mean, 4.0)
}

///|
test "all typed comparison operators and missing fields" {
  for
    pair in [("eq", 1), ("ne", 2), ("gt", 1), ("gte", 2), ("lt", 1), ("lte", 2)] {
    let (op, expected) = pair
    let config = "{\"group_by\":[\"/k\"],\"where\":[{\"path\":\"/v\",\"op\":\"\{op}\",\"value\":2}]}"
    let r = run_query(config, [
      "{\"k\":1,\"v\":1}", "{\"k\":1,\"v\":2}", "{\"k\":1,\"v\":3}", "{\"k\":1}",
    ])
    assert_eq(r.accepted, expected)
    assert_eq(r.filtered, 4 - expected)
  }
  let r = run_query(
    "{\"group_by\":[\"/k\"],\"where\":[{\"path\":\"/v\",\"op\":\"eq\",\"value\":null}]}",
    ["{\"k\":1,\"v\":null}", "{\"k\":1}", "{\"k\":1,\"v\":\"null\"}"],
  )
  assert_eq(r.accepted, 1)
}

///|
test "schema failures stay invalid even when predicate would exclude them" {
  let r = run_query(
    "{\"group_by\":[\"/k\"],\"metrics\":[\"/n\"],\"where\":[{\"path\":\"/env\",\"op\":\"eq\",\"value\":\"prod\"}]}",
    [
      "", "  \r", "bad", "{\"k\":{},\"n\":1}", "{\"k\":1}", "{\"k\":1,\"n\":\"2\"}",
      "{\"k\":1,\"n\":1e400}", "{\"k\":1,\"n\":2,\"env\":\"test\"}",
    ],
  )
  assert_eq(r.lines, 8)
  assert_eq(r.invalid, 5)
  assert_eq(r.invalid_lines, [3, 4, 5, 6, 7])
  assert_eq(r.filtered, 1)
}

///|
test "typed composite keys do not collide and numeric spellings normalize" {
  let r = run_query("{\"group_by\":[\"/a\",\"/b\"]}", [
    "{\"a\":1,\"b\":null}", "{\"a\":1.0,\"b\":null}", "{\"a\":\"1\",\"b\":null}",
    "{\"a\":\"a|b\",\"b\":\"c\"}", "{\"a\":\"a\",\"b\":\"b|c\"}", "{\"a\":-0.0,\"b\":true}",
    "{\"a\":0,\"b\":true}",
  ])
  assert_eq(r.accepted, 7)
  assert_eq(r.groups.length(), 5)
}

///|
test "pointer invalid indexes never wrap or panic" {
  for
    path in [
      "/a/01", "/a/-1", "/a/-", "/a/2147483648", "/a/999999999999999999999", "/a/2",
    ] {
    let r = run_query("{\"metrics\":[\"\{path}\"]}", ["{\"a\":[1,2]}"])
    assert_eq(r.invalid, 1)
  }
}

///|
test "bad configuration fails explicitly" {
  for
    config in [
      "{", "[]", "{}", "{\"group_by\":[\"a\"]}", "{\"group_by\":[\"/~2\"]}", "{\"group_by\":[\"/~\"]}",
      "{\"metrics\":null}", "{\"metrics\":[\"/x\",\"/x\"]}", "{\"metrics\":[\"/x\"],\"max_groups\":0}",
      "{\"metrics\":[\"/x\"],\"max_groups\":1.5}", "{\"metrics\":[\"/x\"],\"typo\":true}",
      "{\"metrics\":[\"/x\"],\"where\":[{\"path\":\"/x\",\"op\":\"gt\",\"value\":\"1\"}]}",
      "{\"metrics\":[\"/x\"],\"where\":[{\"path\":\"/x\",\"op\":\"wat\",\"value\":1}]}",
    ] {
    let rejected = try {
      ignore(@query.Query::parse(config))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "group limit and metric overflow preserve complete prior state" {
  let acc = @query.Accumulator::new(
    @query.Query::parse(
      "{\"group_by\":[\"/k\"],\"metrics\":[\"/a\",\"/b\"],\"max_groups\":1}",
    ),
  )
  acc.push_line("{\"k\":\"a\",\"a\":1,\"b\":1e308}")
  let before = acc.report().to_json()
  let full = try {
    acc.push_line("{\"k\":\"b\",\"a\":1,\"b\":1}")
    false
  } catch {
    _ => true
  }
  assert_true(full)
  assert_eq(acc.report().to_json(), before)
  let overflow = try {
    acc.push_line("{\"k\":\"a\",\"a\":2,\"b\":1e308}")
    false
  } catch {
    _ => true
  }
  assert_true(overflow)
  assert_eq(acc.report().to_json(), before)
  acc.push_line("{\"k\":\"a\",\"a\":2,\"b\":-1e308}")
  assert_eq(acc.report().accepted, 2)
  assert_eq(acc.report().groups[0].metrics[0].sum, 3.0)
}

///|
test "report mutations cannot corrupt accumulator" {
  let acc = @query.Accumulator::new(
    @query.Query::parse("{\"group_by\":[\"/k\"],\"metrics\":[\"/n\"]}"),
  )
  acc.push_line("{\"k\":\"a\",\"n\":2}")
  acc.push_line("bad")
  let before = acc.report().to_json()
  let snapshot = acc.report()
  snapshot.groups[0].key[0] = "corrupt".to_json()
  snapshot.groups[0].metrics.clear()
  snapshot.invalid_lines.clear()
  snapshot.group_by.clear()
  snapshot.groups.clear()
  assert_eq(acc.report().to_json(), before)
}

///|
test "invalid diagnostics are bounded and redact payloads" {
  let acc = @query.Accumulator::new(
    @query.Query::parse("{\"metrics\":[\"/n\"]}"),
  )
  for _ in 0..<130 {
    acc.push_line("private contents")
  }
  let report = acc.report()
  assert_eq(report.invalid, 130)
  assert_eq(report.invalid_lines.length(), 100)
  assert_true(report.invalid_lines_truncated)
  assert_true(!report.to_json().stringify().contains("private"))
}

///|
test "stable sorting and conjunction across unrelated schemas" {
  let config = "{\"group_by\":[\"/stage/name\"],\"metrics\":[\"/seconds\"],\"where\":[{\"path\":\"/branch\",\"op\":\"eq\",\"value\":\"main\"},{\"path\":\"/seconds\",\"op\":\"gte\",\"value\":1}]}"
  let lines = [
    "{\"stage\":{\"name\":\"test\"},\"seconds\":3,\"branch\":\"main\"}", "{\"stage\":{\"name\":\"build\"},\"seconds\":2,\"branch\":\"main\"}",
    "{\"stage\":{\"name\":\"test\"},\"seconds\":5,\"branch\":\"main\"}",
  ]
  let a = run_query(config, lines)
  let b = run_query(config, [lines[2], lines[1], lines[0]])
  assert_eq(a.to_json(), b.to_json())
  assert_eq(a.groups[0].key, ["build".to_json()])
}
