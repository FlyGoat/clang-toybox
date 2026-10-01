#!/usr/bin/env python3
"""Create the Actions matrix; workflow inputs are data, never shell source."""
import json
import os
import re
import shlex
from pathlib import Path


def validate(target):
    if not re.fullmatch(r"[a-zA-Z0-9_.-]+", target["name"]):
        raise ValueError("Invalid profile name")
    if not re.fullmatch(r"mips(?:64|isa32r6|isa64r6)?(?:el)?-(?:[a-zA-Z0-9]+-)?linux-musl(?:n32)?", target["triple"]):
        raise ValueError("Only MIPS Linux musl triples are currently supported")
    flags = shlex.split(target["cflags"])
    # Flags pass through make, configure, and CMake: keep a deliberately simple
    # whitespace-separated format without shell/make metacharacters or paths.
    if any(not re.fullmatch(r"-[a-zA-Z0-9_=+.,:-]+", flag) for flag in flags):
        raise ValueError("CFLAGS must be plain compiler options, e.g. -O2 -march=mips32r2")
    if any(flag.startswith(("--target", "--sysroot", "-resource-dir", "-fuse-ld", "-rtlib", "--rtlib", "-stdlib", "-unwindlib", "--unwindlib")) for flag in flags):
        raise ValueError("The builder owns the target, sysroot, linker, and runtime selection")


def main():
    targets = json.loads(Path("config/targets.json").read_text())
    triple = os.environ.get("INPUT_TRIPLE", "").strip()
    cflags = os.environ.get("INPUT_CFLAGS", "").strip()
    if triple:
        if not cflags:
            raise ValueError("A custom triple requires CFLAGS")
        targets = [{"name": "custom", "triple": triple, "cflags": cflags}]
    elif cflags:
        raise ValueError("Custom CFLAGS require a custom triple")
    for target in targets:
        validate(target)
    sources = json.loads(Path("config/sources.json").read_text())
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write("matrix=" + json.dumps({"include": targets}, separators=(",", ":")) + "\n")
        for name, source in sources.items():
            output.write(f"{name}_ref={source['ref']}\n")


if __name__ == "__main__":
    main()
