#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

sdk = Path(sys.argv[1])
sources = json.loads(Path("config/sources.json").read_text())
for name, source in sources.items():
    actual = subprocess.check_output(["git", "-C", f"sources/{name}", "rev-parse", "HEAD"], text=True).strip()
    if actual != source["ref"]:
        raise ValueError(f"Unexpected {name} source revision: {actual}")
sources["llvm"] = {"repository": "llvm/llvm-project", "ref": os.environ["LLVM_SOURCE_REF"]}
manifest = {
    "profile": os.environ["PROFILE"],
    "triple": os.environ["TARGET_TRIPLE"],
    "cflags": os.environ["TARGET_CFLAGS"],
    "llvm_package_version": os.environ["LLVM_PACKAGE_VERSION"],
    "llvm_major": os.environ["LLVM_MAJOR"],
    "sources": sources,
    "builder_commit": os.environ["GITHUB_SHA"],
    "run_url": f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
    "host": "x86_64 Linux, glibc >= 2.39 (Ubuntu 24.04)",
    "validation": "compile, link and ELF inspection only; target code is not executed",
}
(sdk / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
