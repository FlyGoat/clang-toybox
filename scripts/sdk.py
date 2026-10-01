#!/usr/bin/env python3
"""Write relocatable target drivers and a CMake toolchain file."""
import os
import shlex
import sys
from pathlib import Path

sdk = Path(sys.argv[1])
bootstrap = len(sys.argv) > 2 and sys.argv[2] == "bootstrap"
triple = os.environ["TARGET_TRIPLE"]
flags = shlex.split(os.environ["TARGET_CFLAGS"])
bindir = sdk / "bin"
bindir.mkdir(parents=True, exist_ok=True)
common = '''#!/usr/bin/env bash
set -euo pipefail
sdk=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
toolbin=${LLVM_BINDIR:-$sdk/host/bin}
export LD_LIBRARY_PATH="$sdk/host/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
'''
for name, compiler in [("clang", "clang"), ("clang++", "clang++")]:
    extra = ''
    if name == "clang++":
        extra = ' -stdlib=libc++ -nostdinc++ -isystem "$sdk/rootfs/usr/include/c++/v1"'
    driver = common + (
        'exec "$toolbin/' + compiler + '"'
        ' --target=' + shlex.quote(triple) +
        ' --sysroot="$sdk/rootfs" -resource-dir="$sdk/resource"'
        ' --gcc-toolchain="$sdk/no-gcc" -fintegrated-as'
        ' --ld-path="$toolbin/ld.lld" --rtlib=compiler-rt'
        ' --unwindlib=' + ("none" if bootstrap else "libunwind") +
        ' -L"$sdk/rootfs/usr/lib" ' + shlex.join(flags) + extra + ' "$@"\n'
    )
    path = bindir / f"{triple}-{name}"
    path.write_text(driver)
    path.chmod(0o755)
for alias, target in [("cc", "clang"), ("c++", "clang++")]:
    path = bindir / f"{triple}-{alias}"
    path.unlink(missing_ok=True)
    path.symlink_to(f"{triple}-{target}")
for name in ["ar", "ranlib", "nm", "strip", "objcopy", "objdump", "readelf"]:
    path = bindir / f"{triple}-{name}"
    path.write_text(common + f'exec "$toolbin/llvm-{name}" "$@"\n')
    path.chmod(0o755)

processor = triple.split("-")[0]
(sdk / "toolchain.cmake").write_text(f'''get_filename_component(SDK_ROOT "${{CMAKE_CURRENT_LIST_DIR}}" ABSOLUTE)
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR {processor})
set(CMAKE_SYSROOT "${{SDK_ROOT}}/rootfs")
set(CMAKE_C_COMPILER "${{SDK_ROOT}}/bin/{triple}-clang")
set(CMAKE_CXX_COMPILER "${{SDK_ROOT}}/bin/{triple}-clang++")
set(CMAKE_ASM_COMPILER "${{SDK_ROOT}}/bin/{triple}-clang")
set(CMAKE_C_COMPILER_TARGET {triple})
set(CMAKE_CXX_COMPILER_TARGET {triple})
set(CMAKE_ASM_COMPILER_TARGET {triple})
set(CMAKE_AR "${{SDK_ROOT}}/bin/{triple}-ar")
set(CMAKE_RANLIB "${{SDK_ROOT}}/bin/{triple}-ranlib")
set(CMAKE_STRIP "${{SDK_ROOT}}/bin/{triple}-strip")
set(CMAKE_FIND_ROOT_PATH "${{SDK_ROOT}}/rootfs")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
''')
