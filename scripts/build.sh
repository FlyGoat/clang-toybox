#!/usr/bin/env bash
set -euo pipefail
: "${PROFILE:?}" "${TARGET_TRIPLE:?}" "${TARGET_CFLAGS:?}" "${LLVM_BINDIR:?}"
top=$PWD
sdk="$top/out/clang-toybox-$PROFILE"
rootfs="$sdk/rootfs"
llvm="$top/sources/llvm-project"
jobs=$(nproc)
mkdir -p "$sdk" "$rootfs/usr/include" "$rootfs/usr/lib" "$rootfs/lib" "$top/build"
export SDK_DIR="$sdk"
resource="$sdk/resource"
mkdir -p "$resource"
cp -a "$("$LLVM_BINDIR/clang" --print-resource-dir)/include" "$resource/include"

group() { printf '\n::group::%s\n' "$1"; }
endgroup() { echo '::endgroup::'; }

group 'MIPS Linux UAPI headers (host generators use Clang)'
make -C sources/linux ARCH=mips LLVM=1 CC="$LLVM_BINDIR/clang" \
  HOSTCC="$LLVM_BINDIR/clang" HOSTCXX="$LLVM_BINDIR/clang++" \
  INSTALL_HDR_PATH="$rootfs/usr" headers_install
endgroup

python3 scripts/sdk.py "$sdk" bootstrap
cc="$sdk/bin/$TARGET_TRIPLE-clang"

group 'Configure musl and install its headers before compiler-rt'
mkdir -p build/musl
(
  cd build/musl
  "$top/sources/musl/configure" --target="$TARGET_TRIPLE" --prefix=/usr \
    --libdir=/usr/lib --syslibdir=/lib --disable-wrapper \
    CC="$cc" AR="$LLVM_BINDIR/llvm-ar" RANLIB="$LLVM_BINDIR/llvm-ranlib" \
    CFLAGS="$TARGET_CFLAGS" LDFLAGS='-fuse-ld=lld' LIBCC=bootstrap-not-yet-built
  make -j"$jobs" DESTDIR="$rootfs" install-headers
)
endgroup

group 'Bootstrap compiler-rt builtins and crtbegin/crtend, without libc'
cmake -G Ninja -S "$llvm/compiler-rt/lib/builtins" -B build/builtins \
  -DCMAKE_TOOLCHAIN_FILE="$sdk/toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_FLAGS_RELEASE=-DNDEBUG -DCMAKE_CXX_FLAGS_RELEASE=-DNDEBUG \
  -DCMAKE_C_FLAGS='-ffreestanding -fno-stack-protector' \
  -DCMAKE_CXX_FLAGS='-ffreestanding -fno-stack-protector' \
  -DCMAKE_INSTALL_PREFIX="$top/build/builtins-install" \
  -DLLVM_CMAKE_DIR="$("$LLVM_BINDIR/llvm-config" --cmakedir)" \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
  -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=OFF \
  -DCOMPILER_RT_BUILD_CRT=ON -DCOMPILER_RT_HAS_INITFINI_ARRAY=ON \
  -DCOMPILER_RT_CRT_USE_EH_FRAME_REGISTRY=OFF \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF
cmake --build build/builtins -j "$jobs"
cmake --install build/builtins
# Query the driver rather than guessing endian/ABI-specific resource names.
builtins=$("$cc" -print-libgcc-file-name)
[[ "$builtins" == "$resource/"* ]]
mapfile -t archives < <(find build/builtins-install -name 'libclang_rt.builtins*.a')
[[ ${#archives[@]} == 1 ]]
mkdir -p "$(dirname "$builtins")"
cp "${archives[0]}" "$builtins"
while IFS= read -r object; do
  cp "$object" "$(dirname "$builtins")/"
done < <(find build/builtins-install -name 'clang_rt.crt*.o')
[[ -n "$(find "$resource" -name 'clang_rt.crtbegin*.o' -print -quit)" ]]
endgroup

group 'Build musl libc with compiler-rt; no libgcc'
(
  cd build/musl
  "$top/sources/musl/configure" --target="$TARGET_TRIPLE" --prefix=/usr \
    --libdir=/usr/lib --syslibdir=/lib --disable-wrapper \
    CC="$cc" AR="$LLVM_BINDIR/llvm-ar" RANLIB="$LLVM_BINDIR/llvm-ranlib" \
    CFLAGS="$TARGET_CFLAGS" LDFLAGS='-fuse-ld=lld' LIBCC="$builtins"
  make -j"$jobs"
  make DESTDIR="$rootfs" install
)
# Musl installs an absolute loader symlink. Make it usable both as a rootfs
# and as a relocated sysroot outside chroot.
for loader in "$rootfs"/lib/ld-musl-*.so.1; do
  [[ -L "$loader" ]]
  ln -sfn ../usr/lib/libc.so "$loader"
done
endgroup

group 'Build LLVM libunwind, libc++abi, and libc++ for musl'
cmake -G Ninja -S "$llvm/runtimes" -B build/runtimes \
  -DCMAKE_TOOLCHAIN_FILE="$sdk/toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_FLAGS_RELEASE=-DNDEBUG -DCMAKE_CXX_FLAGS_RELEASE=-DNDEBUG \
  -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DLLVM_ENABLE_RUNTIMES='libunwind;libcxxabi;libcxx' \
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_DOCS=OFF \
  -DLIBUNWIND_USE_COMPILER_RT=ON \
  -DLIBUNWIND_ENABLE_SHARED=ON -DLIBUNWIND_ENABLE_STATIC=ON \
  -DLIBCXXABI_USE_COMPILER_RT=ON -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DLIBCXXABI_ENABLE_SHARED=ON -DLIBCXXABI_ENABLE_STATIC=ON \
  -DLIBCXX_USE_COMPILER_RT=ON -DLIBCXX_HAS_MUSL_LIBC=ON \
  -DLIBCXX_ENABLE_SHARED=ON -DLIBCXX_ENABLE_STATIC=ON \
  -DLIBCXX_CXX_ABI=libcxxabi -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON \
  -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF
cmake --build build/runtimes -j "$jobs"
DESTDIR="$rootfs" cmake --install build/runtimes
python3 scripts/sdk.py "$sdk"
endgroup

group 'Build and install static Toybox, including its shell'
(
  cd sources/toybox
  export CC="$cc" HOSTCC="$LLVM_BINDIR/clang" CROSS_COMPILE=
  export STRIP="$LLVM_BINDIR/llvm-strip" CFLAGS="$TARGET_CFLAGS"
  export LDFLAGS=-static OPTIMIZE="$TARGET_CFLAGS -ffunction-sections -fdata-sections -fno-strict-aliasing" LDOPTIMIZE='-Wl,--gc-sections'
  export CPUS="$jobs"
  make defconfig
  sed -i 's/# CONFIG_SH is not set/CONFIG_SH=y/' .config
  make silentoldconfig
  grep -qx 'CONFIG_SH=y' .config
  make -j"$jobs"
  PREFIX="$rootfs" make install
  cp .config "$sdk/toybox.config"
)
endgroup

group 'Assemble root filesystem'
mkdir -p "$rootfs"/{dev,proc,sys,tmp,run,root,etc,usr/share/licenses}
chmod 1777 "$rootfs/tmp"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$rootfs/etc/passwd"
printf 'root:x:0:\n' > "$rootfs/etc/group"
printf '/usr/lib\n/lib\n' > "$rootfs/etc/ld-musl-$(basename "$rootfs"/lib/ld-musl-*.so.1 | sed 's/^ld-musl-//;s/\.so\.1$//').path"
printf 'NAME="LLVM musl Toybox"\nID=clang-toybox\n' > "$rootfs/etc/os-release"
cat > "$rootfs/init" <<'EOF'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec /bin/sh
EOF
chmod 755 "$rootfs/init"
cp sources/musl/COPYRIGHT "$rootfs/usr/share/licenses/musl.txt"
cp sources/toybox/LICENSE "$rootfs/usr/share/licenses/toybox.txt"
cp sources/linux/LICENSES/preferred/GPL-2.0 "$rootfs/usr/share/licenses/linux-GPL-2.0.txt"
cp sources/linux/LICENSES/exceptions/Linux-syscall-note "$rootfs/usr/share/licenses/linux-syscall-note.txt"
for component in compiler-rt libunwind libcxxabi libcxx; do
  cp "$llvm/$component/LICENSE.TXT" "$rootfs/usr/share/licenses/llvm-$component.txt"
done
endgroup

group 'Bundle host LLVM tools from apt.llvm.org'
mkdir -p "$sdk/host/bin" "$sdk/host/lib" "$sdk/host/licenses"
for tool in clang clang++ ld.lld llvm-ar llvm-ranlib llvm-nm llvm-strip llvm-objcopy llvm-objdump llvm-readelf; do
  cp -L "$LLVM_BINDIR/$tool" "$sdk/host/bin/$tool"
  # Keep glibc and its loader host-provided; carry LLVM and other dependencies.
  while IFS= read -r library; do
    case "$(basename "$library")" in
      libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*.so.*) continue ;;
    esac
    cp -L "$library" "$sdk/host/lib/$(basename "$library")"
  done < <(ldd "$LLVM_BINDIR/$tool" | awk '$2 == "=>" && $3 ~ /^\// { print $3 }')
done
cp -L /usr/share/doc/clang-"$LLVM_MAJOR"/copyright "$sdk/host/licenses/clang.txt"
cp -L /usr/share/doc/llvm-"$LLVM_MAJOR"/copyright "$sdk/host/licenses/llvm.txt"
cp -L /usr/share/doc/lld-"$LLVM_MAJOR"/copyright "$sdk/host/licenses/lld.txt"
cp README.md "$sdk/README.md"
python3 scripts/manifest.py "$sdk"
endgroup
