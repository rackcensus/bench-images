#!/usr/bin/env python3
import json
import pathlib
import platform
import subprocess
import sys

CHECKS = ["wrk", "sysbench", "memtier", "pgbench", "woo"]


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: collect.py <verify out dir> <arch> <unpacked sizes json>")
    out, arch, sizes_path = pathlib.Path(argv[0]), argv[1], argv[2]
    checks = {}
    for check in CHECKS:
        path = out / f"{check}.json"
        if not path.exists():
            raise SystemExit(f"{check} has no result in {out}")
        checks[check] = json.loads(path.read_text())
    docker = subprocess.run(["docker", "version", "-f", "{{.Server.Version}}"], capture_output=True, text=True).stdout.strip()
    result = {
        "arch": arch,
        "platform": f"linux/{arch}",
        "host": {"machine": platform.machine(), "kernel": platform.release(), "docker": docker},
        "sizes": json.loads(pathlib.Path(sizes_path).read_text()),
        "checks": checks,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main(sys.argv[1:])
