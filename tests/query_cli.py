"""Real process checks for the streaming query CLI; fixtures are illustrative data."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOON = os.environ.get("MOON_BIN", "moon")


def run(*args, data=None, package="cmd/query"):
    return subprocess.run(
        [MOON, "run", package, *map(str, args)], cwd=ROOT,
        input=data, capture_output=True, timeout=60, check=False,
    )


class QueryCliTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.config = self.base / "query.json"
        self.write_config({"group_by": ["/k"], "metrics": ["/n"]})

    def write_config(self, value):
        self.config.write_text(json.dumps(value), encoding="utf-8")

    def report(self, result, code=0):
        self.assertEqual(result.returncode, code, result.stderr.decode(errors="replace"))
        return json.loads(result.stdout)

    def test_three_non_http_examples(self):
        expectations = {
            "jobs": (["mail", "ok"], 40, 20),
            "builds": (["compile", "linux"], 30, 15),
            "sensors": (["north", "freezer-a"], -38, -19),
        }
        for name, (key, total, mean) in expectations.items():
            with self.subTest(name=name):
                r = self.report(run(f"examples/{name}.jsonl", f"examples/{name}.query.json"))
                self.assertEqual((r["accepted"], r["filtered"], r["invalid"]), (3, 1, 0))
                group = next(g for g in r["groups"] if g["key"] == key)
                self.assertEqual(group["count"], 2)
                self.assertEqual(group["metrics"][0]["sum"], total)
                self.assertEqual(group["metrics"][0]["mean"], mean)

    def test_stdin_file_crlf_and_unterminated_last_line(self):
        payload = b'\r\n{"k":"x","n":1}\r\n\n{"k":"x","n":3}'
        path = self.base / "events with spaces.jsonl"
        path.write_bytes(payload)
        a = self.report(run(path, self.config))
        b = self.report(run("-", self.config, data=payload))
        self.assertEqual(a, b)
        self.assertEqual((a["lines"], a["accepted"]), (4, 2))
        self.assertEqual(a["groups"][0]["metrics"][0]["mean"], 2)

    def test_empty_input_and_quality_exit_precedence(self):
        r = self.report(run("-", self.config, data=b""))
        self.assertEqual(r["lines"], 0)
        self.assertEqual(r["groups"], [])
        self.report(run("-", self.config, "--min-events", "1", data=b""), 5)
        r = self.report(run("-", self.config, "--fail-on-invalid", "--min-events", "2",
                            data=b'{"k":"x","n":1}\nbad\n'), 4)
        self.assertEqual(r["invalid_lines"], [2])

    def test_invalid_utf8_and_missing_files_emit_no_report(self):
        payload = b'{"k":"x","n":1}\n\xff\n'
        for stdin in (True, False):
            path = self.base / "invalid.jsonl"
            path.write_bytes(payload)
            result = run("-" if stdin else path, self.config, data=payload if stdin else None)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(result.stdout, b"")
        self.assertEqual(run(self.base / "missing", self.config).returncode, 1)
        self.assertEqual(run("-", self.base / "missing", data=b"").returncode, 1)

    def test_argument_and_config_errors(self):
        self.assertEqual(run("--help").returncode, 0)
        self.assertEqual(run().returncode, 2)
        for args in [("--wat",), ("--min-events",), ("--min-events", "0"),
                     ("--min-events", "-1"), ("--min-events", "999999999999")]:
            self.assertEqual(run("-", self.config, *args, data=b"").returncode, 2)
        for config in [{}, {"group_by": ["not-a-pointer"]},
                       {"metrics": ["/n"], "where": [{"path": "/n", "op": "gte", "value": "x"}]}]:
            self.write_config(config)
            result = run("-", self.config, data=b"")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, b"")

    def test_group_limit_and_overflow_do_not_publish_partial_success(self):
        self.write_config({"group_by": ["/k"], "metrics": ["/n"], "max_groups": 1})
        for payload in [b'{"k":"a","n":1}\n{"k":"b","n":2}',
                        b'{"k":"a","n":1e308}\n{"k":"a","n":1e308}']:
            result = run("-", self.config, data=payload)
            self.assertEqual(result.returncode, 8, result.stderr)
            self.assertEqual(result.stdout, b"")

    def test_large_input_small_group_count_and_bounded_diagnostics(self):
        payload = b''.join(json.dumps({"k": str(i % 10), "n": i % 10}).encode() + b'\n'
                           for i in range(20000))
        payload += b'private invalid contents\n' * 150
        r = self.report(run("-", self.config, data=payload))
        self.assertEqual((r["accepted"], r["invalid"], len(r["groups"])), (20000, 150, 10))
        self.assertEqual(len(r["invalid_lines"]), 100)
        self.assertTrue(r["invalid_lines_truncated"])
        self.assertEqual(sum(g["metrics"][0]["sum"] for g in r["groups"]), 90000)
        self.assertNotIn("private", json.dumps(r))

    def test_embedded_public_api_example(self):
        r = self.report(run(package="examples/reuse"))
        self.assertEqual(r["accepted"], 2)
        self.assertEqual(r["groups"][0]["metrics"][0]["mean"], 15)


if __name__ == "__main__":
    unittest.main(verbosity=2)
