#!/usr/bin/env python3
"""Measure complete optimized solves, including startup and a fresh DP memo.

Claim: a fresh full solve on this machine takes the median wall time of five
successful processes. Compilation and the optional profiling run are excluded.
Every timed process must return the known score AND all 947,711 visited states.
Requires Python 3.9+, Mise, and macOS or Linux. No Python dependencies.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from math import isclose
import os
from pathlib import Path
import platform
import re
import resource
import statistics
import subprocess
from tempfile import TemporaryDirectory
import time


ROOT = Path(__file__).resolve().parent
ROC = ["mise", "exec", "--", "roc"]
EXPECTED_SCORE = 248.4399893778553
EXPECTED_STATES = 947711


def checked_solve(binary):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.perf_counter()
    result = subprocess.run([str(binary), "solve"], capture_output=True, text=True, check=True)
    wall = time.perf_counter() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    match = re.fullmatch(r"expected-additional-score=([^ ]+) states=(\d+)\s*", result.stdout)
    if not match or result.stderr:
        raise RuntimeError(f"Unexpected solver output: {result.stdout!r} {result.stderr!r}")
    score, states = float(match[1]), int(match[2])
    if not isclose(score, EXPECTED_SCORE, abs_tol=1e-8, rel_tol=1e-10) or states != EXPECTED_STATES:
        raise RuntimeError(f"Incomplete or incorrect solve: {score}, {states}")
    return {
        "wall_seconds": wall,
        "cpu_seconds": after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
        "score": score,
        "states": states,
    }


def machine():
    info = {"os": platform.platform(), "architecture": platform.machine(), "logical_cpus": os.cpu_count()}
    if platform.system() == "Darwin":
        for key, setting in (("cpu", "machdep.cpu.brand_string"), ("memory_bytes", "hw.memsize")):
            value = subprocess.check_output(["sysctl", "-n", setting], text=True).strip()
            info[key] = int(value) if key == "memory_bytes" else value
    else:
        info["cpu"] = platform.processor()
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--output", type=Path, help="save raw samples and machine/compiler metadata as JSON")
    parser.add_argument("--profile", type=Path, help="save an untimed macOS sample call graph")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.profile and platform.system() != "Darwin":
        parser.error("--profile uses the macOS sample command; omit it on Linux")

    compiler = subprocess.check_output([*ROC, "--version"], cwd=ROOT, text=True).strip()
    sources = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
               for name in ("main.roc", "Solver.roc", "Yatzy.roc", "mise.toml")}
    data = {
        "date_utc": datetime.now(timezone.utc).isoformat(),
        "machine": machine(), "compiler": compiler,
        "build_flags": ["--opt=speed", "--debug"],
        "workload": "solve: all 15 categories, upper subtotal 0; fresh process and memo every run",
        "includes": "process startup, full DP computation, result printing",
        "excludes": "compilation, package downloads, optional separate profiling run",
        "source_sha256": sources,
        "samples": [],
    }
    with TemporaryDirectory(prefix="yatzy-benchmark-", dir="/var/tmp") as scratch:
        binary = Path(scratch) / "yatzy"
        subprocess.run([*ROC, "build", "--opt=speed", "--debug", f"--output={binary}", "main.roc"], cwd=ROOT, check=True)
        if args.profile:
            args.profile.parent.mkdir(parents=True, exist_ok=True)
            with subprocess.Popen([str(binary), "solve"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                try:
                    # Give the process time to start; this run is never timed.
                    time.sleep(0.2)
                    subprocess.run(["sample", str(process.pid), "1", "-file", str(args.profile.resolve())], check=True)
                except BaseException:
                    process.terminate()
                    process.wait()
                    raise
                stdout, stderr = process.communicate()
                if process.returncode != 0 or stderr or f"states={EXPECTED_STATES}" not in stdout:
                    raise RuntimeError(f"Profile run failed: {stdout} {stderr}")
            # Keep the call graph, without process IDs, local paths or loaded libraries.
            raw = args.profile.read_text()
            graph = raw.split("Call graph:\n", 1)[1].split("Binary Images:", 1)[0]
            graph = re.sub(r"Thread_\d+", "main thread", graph)
            args.profile.write_text("Untimed macOS sample: 1 second, 1 ms sampling interval.\n\nCall graph:\n" + graph.rstrip() + "\n")
            data["profile"] = args.profile.name

        data["load_average_before"] = os.getloadavg()
        for index in range(args.runs):
            row = checked_solve(binary)
            data["samples"].append(row)
            print(f"Run {index + 1}/{args.runs}: {row['wall_seconds']:.3f} s; {row['states']:,} states; score {row['score']}", flush=True)
        data["load_average_after"] = os.getloadavg()

    samples = data["samples"]
    times = [row["wall_seconds"] for row in samples]
    data["median_seconds"] = statistics.median(times)
    data["min_seconds"], data["max_seconds"] = min(times), max(times)
    data["median_cpu_to_wall_ratio"] = statistics.median(row["cpu_seconds"] / row["wall_seconds"] for row in samples)
    data["successful_runs"], data["failed_runs"] = len(samples), 0
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Median {data['median_seconds']:.3f} s; range {min(times):.3f}–{max(times):.3f} s; {len(samples)} verified fresh solves.")


if __name__ == "__main__":
    main()
