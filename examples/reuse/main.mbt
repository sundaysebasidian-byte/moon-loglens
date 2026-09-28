///|
/// An embedding application supplies records itself; the library performs no I/O.
fn main {
  let plan = @lens.Query::parse(
    "{\"group_by\":[\"/pipeline\"],\"metrics\":[\"/seconds\"]}",
  ) catch {
    _ => abort("invalid example query")
  }
  let accumulator = @lens.Accumulator::new(plan)
  for
    line in [
      "{\"pipeline\":\"release\",\"seconds\":12}", "{\"pipeline\":\"release\",\"seconds\":18}",
    ] {
    accumulator.push_line(line) catch {
      _ => abort("example exceeded limits")
    }
  }
  println(accumulator.report().to_json().stringify())
}
