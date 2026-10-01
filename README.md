# Clang + musl + Toybox

GitHub Actions builds a MIPS root filesystem and cross-compilation SDK using
LLVM main snapshots from [apt.llvm.org](https://apt.llvm.org/).
Every target produces **one combined tarball** containing the runtime and SDK.
Builds run on pushes, pull requests, manual dispatch, and **Mondays at 03:23 UTC**.
Weekly and published manual builds create GitHub releases; every successful
matrix job also uploads an Actions artifact.

## Targets and flags

The matrix lives in [config/targets.json](config/targets.json):

| Profile | Triple | CPU / ABI / floating point |
| --- | --- | --- |
| `mips32r2` | `mips-linux-musl` | MIPS32r2, O32, hard float, FP32, `-O2` |
| `mipsel32r2` | `mipsel-linux-musl` | Same, little endian |
| `mips32r2-soft` | `mips-linux-musl` | MIPS32r2, O32, soft float, `-Os` |
| `mipsel32r2-soft` | `mipsel-linux-musl` | Same, little endian |
| `mips64r2` | `mips64-linux-musl` | MIPS64r2, N64, hard float, `-O2` |
| `mips64elr2` | `mips64el-linux-musl` | Same, little endian |
| `mips32r6` | `mipsisa32r6-linux-musl` | MIPS32r6, O32, hard float, FP64, `-O2` |
| `mipsel32r6` | `mipsisa32r6el-linux-musl` | Same, little endian |

Use **Actions → LLVM musl Toybox → Run workflow** for a custom triple and CFLAGS.
Leave both empty for the complete matrix. Custom flags must be plain
whitespace-separated compiler options; the builder owns the sysroot and runtime
selection. Choose a triple matching the ABI and endianness in the flags.
Each job builds a separate sysroot, so profiles sharing a triple do not mix ABIs.

```sh
gh workflow run build.yml --repo flygoat/clang-toybox \
  -f triple=mipsel-linux-musl \
  -f cflags='-Os -march=mips32r2 -mabi=32 -msoft-float'
```

## Bootstrap

1. Install Clang, LLD, LLVM tools, and LLVM CMake files from the **unversioned
   development suite** `llvm-toolchain-noble`, with apt.llvm.org preferred over
   Ubuntu's packages. The workflow discovers the current development major
   from versioned snapshot packages, because LLVM meta-packages can lag behind.
2. Resolve the upstream revision encoded in the installed Clang Debian package
   and check out matching LLVM runtime sources.
3. Export MIPS Linux UAPI headers and configure musl to install libc headers.
4. Cross-build compiler-rt builtins and compiler-rt CRT objects without linking
   a target executable. Install them into the SDK's private Clang resource dir.
5. Build musl with the freshly built compiler-rt archive as `LIBCC`.
6. Build shared and static LLVM libunwind, libc++abi, and libc++ against musl.
7. Build static Toybox, explicitly enable its shell, and install applet links.
8. Assemble the rootfs and bundle the host LLVM tools from apt.llvm.org.

Target compilation uses Clang's integrated assembler, LLD, LLVM archive tools,
compiler-rt, LLVM libunwind, and libc++. Target binaries and runtime libraries
are checked for accidental libgcc, libstdc++, or glibc dependencies.
Host LLVM packages retain their normal Ubuntu shared library dependencies;
this does not add GNU runtimes to the MIPS rootfs.

Musl 1.2.6, Toybox 0.8.14, and Linux 6.12 UAPI sources are pinned by commit in
[config/sources.json](config/sources.json). LLVM intentionally tracks apt's main
snapshot. Each bundle records all source revisions, the apt package version,
flags, builder commit, and run URL in `manifest.json`.

## Bundle layout and use

```text
clang-toybox-<profile>/
  rootfs/              MIPS rootfs; also the SDK sysroot
    bin/toybox         static multicall binary with applet symlinks
    bin/sh             Toybox shell
    lib/ld-musl-*.so.1 musl loader
    usr/lib/           libc and shared/static C++ runtime libraries
    usr/include/       musl, MIPS Linux UAPI, and libc++ headers
    init               minimal shell-based /init
  bin/<triple>-clang   relocatable cross-compiler drivers
  bin/<triple>-clang++ C++ driver using libc++ and libunwind
  bin/<triple>-*       LLVM ar, ranlib, strip, objcopy, nm, etc.
  host/               selected x86_64 host LLVM tools and shared dependencies
  resource/           Clang builtin headers, compiler-rt builtins and CRT
  toolchain.cmake     CMake cross-compilation configuration
  manifest.json       exact build inputs
  toybox.config       installed applet configuration
```

The SDK runs on **x86_64 Linux with glibc 2.39 or newer** (Ubuntu 24.04 or
compatible), plus Bash. Extract the archive anywhere; the driver paths are
computed relative to the archive. The native compiler runs on the host, while
everything under `rootfs/` is for MIPS.

```sh
tar -xf clang-toybox-mipsel32r2.tar.xz
sdk="$PWD/clang-toybox-mipsel32r2"
"$sdk/bin/mipsel-linux-musl-clang" hello.c -o hello
"$sdk/bin/mipsel-linux-musl-clang++" -static hello.cpp -o hello-cxx
cmake -S project -B build -DCMAKE_TOOLCHAIN_FILE="$sdk/toolchain.cmake"
```

`LLVM_BINDIR` optionally selects a compatible external host LLVM installation.
The default uses the tools carried in the bundle.

Actions performs C/C++ compile and link checks for shared and static runtimes,
checks ELF dependencies, and verifies SDK relocation. **There is no QEMU or
target execution.** The rootfs includes development headers and static archives
because it is also the SDK sysroot. No kernel or initramfs image is built.
To boot the tree, supply a suitable MIPS Linux kernel and use `/init` or your
own init system. The provided `/init` mounts procfs, sysfs, and devtmpfs and
starts a shell.
