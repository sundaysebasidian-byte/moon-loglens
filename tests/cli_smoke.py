"""End-to-end checks for the native CLI and its process exit codes."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MOON = os.environ.get("MOON_BIN", "moon")


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [MOON, "run", "cmd/main", *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


class CliSmokeTest(unittest.TestCase):
    def test_reports_and_json_filter(self) -> None:
        result = run_cli("examples/requests.jsonl")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("accepted=4 filtered=0 invalid=1", result.stdout)
        self.assertIn('service="api" requests=3', result.stdout)

        result = run_cli(
            "examples/requests.jsonl", "--service", "api", "--level", "ERROR",
            "--format", "json",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual((report["accepted"], report["errors"]), (1, 1))

        result = run_cli(
            "examples/requests.jsonl", "--status", "200", "--format", "json",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["accepted"], 3)
        self.assertEqual(report["filtered"], 1)
        self.assertTrue(all(group["status"] == 200 for group in report["statuses"]))

    def test_strict_mode_and_gate_precedence(self) -> None:
        for args in (
            ("--fail-on-invalid",),
            ("--service", "worker", "--fail-on-invalid"),
            ("--fail-on-invalid", "--min-events", "5", "--max-error-rate", "20"),
        ):
            with self.subTest(args=args):
                result = run_cli("examples/requests.jsonl", *args)
                self.assertEqual(result.returncode, 4, result.stderr)
                self.assertIn("invalid_lines=5", result.stdout)
        with tempfile.TemporaryDirectory() as directory:
            clean = Path(directory) / "clean.jsonl"
            sample = (ROOT / "examples" / "requests.jsonl").read_text(encoding="utf-8")
            clean.write_text(sample.splitlines()[0] + "\n", encoding="utf-8")
            result = run_cli(
                str(clean), "--fail-on-invalid", "--min-events", "1",
                "--max-error-rate", "0",
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_minimum_sample_and_error_rate(self) -> None:
        cases = [
            (("--min-events", "5"), 5),
            (("--min-events", "4"), 0),
            (("--max-error-rate", "20"), 3),
            (("--max-error-rate", "25"), 0),
        ]
        for args, code in cases:
            with self.subTest(args=args):
                result = run_cli("examples/requests.jsonl", *args)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn("accepted=4", result.stdout)

    def test_latency_gate_uses_global_p95(self) -> None:
        result = run_cli("examples/requests.jsonl", "--max-p95-ms", "149")
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertIn("p95_ms=150", result.stdout)
        result = run_cli("examples/requests.jsonl", "--max-p95-ms", "150")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run_cli("examples/requests.jsonl", "--max-p95-ms", "149", "--format", "json")
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertEqual(json.loads(result.stdout)["p95_ms"], 150)

    def test_empty_sample_cannot_pass_error_rate_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            empty = Path(directory) / "empty.jsonl"
            empty.write_text("\n", encoding="utf-8")
            for args in (
                (str(empty), "--max-error-rate", "0"),
                ("examples/requests.jsonl", "--service", "missing", "--max-error-rate", "0"),
                ("examples/requests.jsonl", "--service", "missing", "--max-p95-ms", "0"),
            ):
                with self.subTest(args=args):
                    result = run_cli(*args)
                    self.assertEqual(result.returncode, 3 if "--max-error-rate" in args else 6, result.stderr)
                    self.assertIn("accepted=0", result.stdout)

    def test_bad_cli_and_file_fail(self) -> None:
        cases = [
            (("examples/requests.jsonl", "--min-events", "0"), 2),
            (("examples/requests.jsonl", "--status", "99"), 2),
            (("examples/requests.jsonl", "--status", "nope"), 2),
            (("examples/requests.jsonl", "--max-p95-ms", "-1"), 2),
            (("examples/requests.jsonl", "--since", "2026-02-29T00:00:00Z"), 2),
            (("examples/requests.jsonl", "--wrong", "yes"), 2),
            (("examples/missing.jsonl",), 1),
        ]
        for args, code in cases:
            with self.subTest(args=args):
                result = run_cli(*args)
                self.assertEqual(result.returncode, code, result.stderr)


if __name__ == "__main__":
    unittest.main()
