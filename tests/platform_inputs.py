"""Real host CLI input boundaries; this does not emulate a Windows runtime."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOON = os.environ.get("MOON_BIN", "moon")
RUNS = []


class PlatformInputTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="loglens-inputs-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name) / "验收 inputs with spaces & brackets [1]"
        self.base.mkdir()
        self.config = self.base / "查询 config.json"
        self.config.write_bytes(b'{"group_by":["/k"],"metrics":["/n"]}\r\n')

    def run_cli(self, *args, package="cmd/query", data=None):
        command = [MOON, "run", "-j", "1", package, *map(str, args)]
        result = subprocess.run(command, cwd=ROOT, input=data, capture_output=True, timeout=60)
        RUNS.append({"test": self.id(), "command": command, "exit_code": result.returncode,
                     "stdin_sha256": hashlib.sha256(data).hexdigest() if data is not None else None,
                     "stdout": result.stdout.decode("utf-8", errors="replace"),
                     "stderr": result.stderr.decode("utf-8", errors="replace")})
        return result

    def report(self, result, code=0):
        self.assertEqual(result.returncode, code, result.stderr.decode(errors="replace"))
        return json.loads(result.stdout)

    def test_query_unicode_paths_crlf_and_windows_string_values(self):
        key = "C:\\日志 files\\构建.jsonl"
        rows = [{"来源": key, "n": 1}, {"来源": key, "n": 3}]
        payload = b'\r\n' + b'\r\n'.join(json.dumps(r, ensure_ascii=False).encode("utf-8") for r in rows)
        self.config.write_bytes('{"group_by":["/来源"],"metrics":["/n"]}\r\n'.encode("utf-8"))
        path = self.base / "构建 events #1.jsonl"
        path.write_bytes(payload)
        a = self.report(self.run_cli(path, self.config))
        b = self.report(self.run_cli("-", self.config, data=payload))
        self.assertEqual(a, b)
        self.assertEqual((a["lines"], a["accepted"], a["invalid"]), (3, 2, 0))
        self.assertEqual(a["groups"][0]["key"], [key])
        self.assertEqual(a["groups"][0]["metrics"][0]["mean"], 2)

    def test_http_unicode_filename_and_crlf_matches_lf(self):
        rows = [json.loads(s) for s in (ROOT / "examples/requests.jsonl").read_text().splitlines()[:2]]
        for row in rows:
            row["service"] = "服务 api"
        encoded = [json.dumps(r, ensure_ascii=False).encode("utf-8") for r in rows]
        reports = []
        for name, ending in [("LF", b'\n'), ("CRLF", b'\r\n')]:
            path = self.base / f"请求 {name}.jsonl"
            path.write_bytes(ending.join(encoded))
            reports.append(self.report(self.run_cli(path, "--format", "json", package="cmd/main")))
        self.assertEqual(reports[0], reports[1])
        self.assertEqual(reports[0]["accepted"], 2)
        self.assertEqual(reports[0]["invalid"], 0)

    def test_query_exit_codes_with_crlf_and_unicode_paths(self):
        path = self.base / "质量 gates.jsonl"
        path.write_bytes(b'{"k":"a","n":1}\r\nbad\r\n')
        self.assertEqual(self.report(self.run_cli(path, self.config))["invalid_lines"], [2])
        self.report(self.run_cli(path, self.config, "--fail-on-invalid"), 4)
        self.report(self.run_cli(path, self.config, "--min-events", "2"), 5)
        self.report(self.run_cli(path, self.config, "--fail-on-invalid", "--min-events", "2"), 4)
        for args, code in [
            ((self.base / "不存在 missing.jsonl", self.config), 1),
            ((path, self.config, "--wrong"), 2),
        ]:
            r = self.run_cli(*args)
            self.assertEqual(r.returncode, code)
            self.assertEqual(r.stdout, b"")
        self.config.write_bytes(b'{"group_by":["/k"],"metrics":["/n"],"max_groups":1}\r\n')
        path.write_bytes(b'{"k":"a","n":1}\r\n{"k":"b","n":2}')
        r = self.run_cli(path, self.config)
        self.assertEqual(r.returncode, 8)
        self.assertEqual(r.stdout, b"")

    def test_utf16_and_legacy_bytes_rejected_without_report(self):
        payloads = [b'\xff\xfe' + '{"k":"x","n":1}\r\n'.encode("utf-16-le"),
                    b'{"k":"caf\xe9","n":1}\r\n']
        for payload in payloads:
            path = self.base / "编码 input.jsonl"
            path.write_bytes(payload)
            for args, data, package in [
                ((path, self.config), None, "cmd/query"),
                (("-", self.config), payload, "cmd/query"),
                ((path, "--format", "json"), None, "cmd/main"),
            ]:
                r = self.run_cli(*args, package=package, data=data)
                self.assertEqual(r.returncode, 1)
                self.assertEqual(r.stdout, b"")
        self.config.write_bytes(b'\xff\xfe' + '{"metrics":["/n"]}'.encode("utf-16-le"))
        r = self.run_cli("-", self.config, data=b'{"n":1}\r\n')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, b"")

    def test_utf8_bom_is_not_silently_removed(self):
        path = self.base / "BOM query.jsonl"
        path.write_bytes(b'\xef\xbb\xbf{"k":"x","n":1}\r\n')
        r = self.report(self.run_cli(path, self.config, "--fail-on-invalid"), 4)
        self.assertEqual((r["accepted"], r["invalid"], r["invalid_lines"]), (0, 1, [1]))
        row = (ROOT / "examples/requests.jsonl").read_bytes().splitlines()[0]
        path.write_bytes(b'\xef\xbb\xbf' + row + b'\r\n')
        r = self.report(self.run_cli(path, "--fail-on-invalid", "--format", "json", package="cmd/main"), 4)
        self.assertEqual((r["accepted"], r["invalid"]), (0, 1))
        self.config.write_bytes(b'\xef\xbb\xbf{"metrics":["/n"]}\r\n')
        r = self.run_cli("-", self.config, data=b'{"n":1}\r\n')
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, b"")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PlatformInputTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    output = os.environ.get("LOGLENS_BOUNDARY_OUTPUT")
    if output:
        Path(output).write_text(json.dumps({
            "at_utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
            "runtime": "host native CLI; no Windows kernel or Wine emulation",
            "head_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "tests_run": result.testsRun, "success": result.wasSuccessful(), "process_runs": RUNS,
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() else 1)
