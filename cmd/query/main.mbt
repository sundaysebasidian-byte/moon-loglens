///|
extern "C" fn exit(code : Int) = "exit"

///|
fn usage() -> String {
  "Usage: moon run cmd/query <input.jsonl|-> <query.json> [--fail-on-invalid] [--min-events COUNT]\n"
}

///|
async fn consume(reader : &@io.Reader, acc : @lens.Accumulator) -> Unit {
  while reader.read_until("\n") is Some(line) {
    acc.push_line(line)
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    @stdio.stdout.write(usage())
    return
  }
  if args.length() < 3 {
    @stdio.stderr.write(usage())
    exit(2)
    return
  }
  let mut fail_on_invalid = false
  let mut min_events = 0
  let mut i = 3
  while i < args.length() {
    match args[i] {
      "--fail-on-invalid" => fail_on_invalid = true
      "--min-events" => {
        if i + 1 >= args.length() {
          @stdio.stderr.write("error: missing --min-events value\n")
          exit(2)
          return
        }
        i += 1
        let value = Some(@string.parse_int(args[i])) catch { _ => None }
        guard value is Some(n) && n > 0 else {
          @stdio.stderr.write(
            "error: --min-events must be a positive integer\n",
          )
          exit(2)
          return
        }
        min_events = n
      }
      _ => {
        @stdio.stderr.write("error: unknown option\n" + usage())
        exit(2)
        return
      }
    }
    i += 1
  }
  let source = @fs.read_file(args[2]).text() catch {
    _ => {
      @stdio.stderr.write("error: cannot read UTF-8 query file\n")
      exit(1)
      return
    }
  }
  let plan = @lens.Query::parse(source) catch {
    @lens.InvalidQuery(message) | @lens.LimitExceeded(message) => {
      @stdio.stderr.write("error: \{message}\n")
      exit(2)
      return
    }
  }
  let acc = @lens.Accumulator::new(plan)
  try {
    if args[1] == "-" {
      consume(@stdio.stdin, acc)
    } else {
      let file = @fs.open(args[1], mode=ReadOnly)
      defer file.close()
      consume(file, acc)
    }
  } catch {
    @lens.LimitExceeded(message) => {
      @stdio.stderr.write("error: \{message}; no complete report emitted\n")
      exit(8)
      return
    }
    _ => {
      @stdio.stderr.write(
        "error: cannot read UTF-8 input; no complete report emitted\n",
      )
      exit(1)
      return
    }
  }
  let report = acc.report()
  @stdio.stdout.write(report.to_json().stringify() + "\n")
  if fail_on_invalid && report.invalid > 0 {
    exit(4)
  }
  if report.accepted < min_events {
    exit(5)
  }
}
