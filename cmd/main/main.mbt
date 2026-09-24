///|
extern "C" fn exit(code : Int) = "exit"

///|
fn usage() -> String {
  "Usage: moon run cmd/main <input.jsonl> [--service NAME] [--level DEBUG|INFO|WARN|ERROR] [--status 100..599] [--since UTC] [--until UTC] [--format text|json] [--max-error-rate PERCENT] [--min-events COUNT] [--fail-on-invalid]\n"
}

///|
async fn bad_argument(message : String) -> Unit {
  @stdio.stderr.write("error: \{message}\n" + usage())
  exit(2)
}

///|
async fn main {
  let args = @env.args()
  if args.length() < 2 || args[1] == "--help" || args[1] == "-h" {
    @stdio.stdout.write(usage())
    if args.length() < 2 {
      exit(2)
    }
    return
  }
  let path = args[1]
  if path.has_prefix("-") {
    bad_argument("input file must be the first argument")
    return
  }
  let mut service = ""
  let mut level = ""
  let mut status = 0
  let mut since = ""
  let mut until = ""
  let mut format = "text"
  let mut maximum : Double? = None
  let mut minimum_events = 0
  let mut fail_on_invalid = false
  let mut i = 2
  while i < args.length() {
    if args[i] == "--fail-on-invalid" {
      fail_on_invalid = true
      i += 1
      continue
    }
    if i + 1 >= args.length() {
      bad_argument("missing value for \{args[i]}")
      return
    }
    let value = args[i + 1]
    match args[i] {
      "--service" => service = value
      "--level" => level = value
      "--status" => {
        let parsed = Some(@string.parse_int(value)) catch { _ => None }
        match parsed {
          Some(n) => status = n
          None => {
            bad_argument("--status must be an HTTP status from 100 through 599")
            return
          }
        }
      }
      "--since" => since = value
      "--until" => until = value
      "--format" => format = value
      "--min-events" => {
        let parsed = Some(@string.parse_int(value)) catch { _ => None }
        match parsed {
          Some(n) => {
            if n < 1 {
              bad_argument("--min-events must be a positive integer")
              return
            }
            minimum_events = n
          }
          None => {
            bad_argument("--min-events must be a positive integer")
            return
          }
        }
      }
      "--max-error-rate" => {
        let parsed = Some(@string.parse_double(value)) catch { _ => None }
        match parsed {
          Some(n) => {
            if n.is_nan() || n < 0.0 || n > 100.0 {
              bad_argument("--max-error-rate must be between 0 and 100")
              return
            }
            maximum = Some(n)
          }
          None => {
            bad_argument("--max-error-rate must be a number")
            return
          }
        }
      }
      _ => {
        bad_argument("unknown option \{args[i]}")
        return
      }
    }
    i += 2
  }
  if format != "text" && format != "json" {
    bad_argument("--format must be text or json")
    return
  }
  let config = @app.Config::new(service~, level~, status~, since~, until~)
  if config.validate() is Some(message) {
    bad_argument(message)
    return
  }
  let content = @fs.read_file(path).text() catch {
    _ => {
      @stdio.stderr.write("error: cannot read input file\n")
      exit(1)
      return
    }
  }
  let report = @app.analyze(content, config~)
  if format == "json" {
    @stdio.stdout.write(report.to_json().stringify() + "\n")
  } else {
    @stdio.stdout.write(report.to_text())
  }
  if fail_on_invalid && report.invalid > 0 {
    exit(4)
  }
  if minimum_events > 0 && report.accepted < minimum_events {
    exit(5)
  }
  if maximum is Some(limit) &&
    (report.accepted == 0 || report.error_rate_pct > limit) {
    exit(3)
  }
}
