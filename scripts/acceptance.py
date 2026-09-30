"""Serial, fail-fast acceptance evidence using installed tools and official packages."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New evidence directory outside the repository")
    parser.add_argument("--consumer-only", action="store_true", help="Only verify the published package")
    args = parser.parse_args()
    started = datetime.now(timezone.utc)
    output = (args.output or ROOT.parent / "acceptance-evidence" / started.strftime("%Y%m%dT%H%M%SZ")).resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("--output must be outside the repository")
    output.mkdir(parents=True, exist_ok=False)
    moon = shutil.which(os.environ.get("MOON_BIN", "moon"))
    evidence = {
        "started_at_utc": started.isoformat(), "head_sha": git("rev-parse", "HEAD"),
        "branch": git("branch", "--show-current"), "working_tree_status": git("status", "--short"),
        "platform": platform.platform(), "machine": platform.machine(),
        "python": sys.version, "moon_bin": moon, "moon_home": os.environ.get("MOON_HOME"),
        "consumer_only": args.consumer_only, "stages": [], "overall_exit_code": 1,
    }
    paths = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    evidence["source_sha256"] = {name: sha256(ROOT / name) for name in sorted(set(paths)) if name and (ROOT / name).is_file()}
    env = dict(os.environ)
    if moon:
        env["MOON_BIN"] = moon
        env["PATH"] = str(Path(moon).parent) + os.pathsep + env.get("PATH", "")

    def run(name, command, cwd=ROOT):
        stage = {"name": name, "command": command, "cwd": str(cwd), "exit_code": None}
        evidence["stages"].append(stage)
        begin = time.monotonic()
        print(f"RUN {name}", flush=True)
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, timeout=300)
        stage.update(exit_code=result.returncode, seconds=round(time.monotonic() - begin, 3))
        for stream in ("stdout", "stderr"):
            filename = f"{name}.{stream}.txt"
            (output / filename).write_bytes(getattr(result, stream))
            stage[stream] = filename
        print(f"EXIT {result.returncode} {name}", flush=True)
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {output}")
        return result.stdout.decode("utf-8")

    def require(condition, message):
        if not condition:
            raise RuntimeError(message)

    try:
        require(moon is not None, "moon is missing; install no tools automatically")
        evidence["toolchain"] = run("toolchain", [moon, "version", "--all"])
        # A fresh module outside this checkout cannot resolve a same-module package.
        with tempfile.TemporaryDirectory(prefix="loglens-registry-") as temp:
            consumer = Path(temp)
            for name in ("moon.mod", "moon.pkg", "main.mbt"):
                shutil.copyfile(ROOT / "tests/registry_consumer" / name, consumer / name)
                shutil.copyfile(consumer / name, output / f"consumer-{name}")
            run("consumer-update", [moon, "update"], consumer)
            run("consumer-check", [moon, "check", "--target", "native", "-j", "1"], consumer)
            package = consumer / ".mooncakes/sundaysebasidian-byte/moon-loglens"
            manifest = package / "moon.mod"
            require(manifest.is_file(), "Registry package manifest is missing")
            text = manifest.read_text()
            require('version = "0.2.0"' in text, "Resolved package is not 0.2.0")
            require(not package.is_symlink(), "Registry package must not be a local source override")
            shutil.copyfile(manifest, output / "resolved-loglens-moon.mod")
            evidence["registry_consumer"] = {
                "module": "loglens-acceptance/consumer", "dependency": "sundaysebasidian-byte/moon-loglens@0.2.0",
                "local_path_override": False, "package_sha256": {
                    str(p.relative_to(package)): sha256(p) for p in sorted(package.rglob("*")) if p.is_file()
                },
            }
            report = json.loads(run("consumer-run", [moon, "run", "."], consumer))
            expected = {
                "lines": 2, "accepted": 2, "filtered": 0, "invalid": 0,
                "invalid_lines": [], "invalid_lines_truncated": False,
                "group_by": ["/pipeline"], "metric_fields": ["/seconds"],
                "groups": [{"key": ["release"], "count": 2,
                            "metrics": [{"sum": 30, "min": 12, "max": 18, "mean": 15}]}],
            }
            require(report == expected, f"Consumer report differs: {report}")
            evidence["registry_consumer"]["assertions"] = "passed: full JSON report equals expected"
        if not args.consumer_only:
            run("update", [moon, "update"])
            run("check", [moon, "check", "--target", "native", "-j", "1"])
            run("build", [moon, "build", "--target", "native", "-j", "1"])
            run("moon-tests", [moon, "test", "--target", "native", "-j", "1"])
            run("http-cli-tests", [sys.executable, "tests/cli_smoke.py"])
            run("query-cli-tests", [sys.executable, "tests/query_cli.py"])
            run("platform-input-tests", [sys.executable, "tests/platform_inputs.py"])
            for name, key, total, mean in (
                ("jobs", ["mail", "ok"], 40, 20),
                ("builds", ["compile", "linux"], 30, 15),
                ("sensors", ["north", "freezer-a"], -38, -19),
            ):
                report = json.loads(run(f"example-{name}", [moon, "run", "cmd/query", f"examples/{name}.jsonl", f"examples/{name}.query.json"]))
                require((report["accepted"], report["filtered"], report["invalid"]) == (3, 1, 0), f"{name}: wrong row counts")
                group = next(g for g in report["groups"] if g["key"] == key)
                require((group["count"], group["metrics"][0]["sum"], group["metrics"][0]["mean"]) == (2, total, mean), f"{name}: wrong aggregate")
                evidence["stages"][-1]["assertions"] = "passed: counts, group, sum and mean"
        evidence["overall_exit_code"] = 0
    except (OSError, RuntimeError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        evidence["error"] = str(error)
        print(f"FAIL {error}", file=sys.stderr)
    finally:
        evidence["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        (output / "manifest.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Evidence: {output}")
    return evidence["overall_exit_code"]


if __name__ == "__main__":
    sys.exit(main())
