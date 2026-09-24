// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "sundaysebasidian-byte/moon-loglens"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/sundaysebasidian-byte/moon-loglens"

license = "Apache-2.0"

keywords = [ "jsonl", "logs", "cli", "observability" ]

preferred_target = "native"

description = "Validate and summarize JSONL request logs with a native MoonBit CLI"

import {
  "moonbitlang/async@0.20.2",
}
