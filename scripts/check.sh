#!/usr/bin/env bash
set -euo pipefail
: "${PROFILE:?}" "${TARGET_TRIPLE:?}"
top=$PWD
original="$top/out/clang-toybox-$PROFILE"
# Move the bundle to prove its drivers do not retain build-time absolute paths.
relocated="$top/build/relocated-sdk"
mv "$original" "$relocated"
trap 'mv "$relocated" "$original"' EXIT
sdk=$relocated
rootfs="$sdk/rootfs"
unset LLVM_BINDIR
cc="$sdk/bin/$TARGET_TRIPLE-clang"
cxx="$sdk/bin/$TARGET_TRIPLE-clang++"
readelf="$sdk/bin/$TARGET_TRIPLE-readelf"
mkdir -p build/check

cat > build/check/hello.c <<'EOF'
#include <stdio.h>
#include <stdint.h>
volatile uint64_t divisor = 37;
int main(void) {
  printf("%llu\n", (unsigned long long)(UINT64_C(123456789012345) / divisor));
  return 0;
}
EOF
cat > build/check/hello.cpp <<'EOF'
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
int main() {
  std::vector<int> values{1, 2, 3};
  std::thread worker([&] { values.push_back(4); });
  worker.join();
  try { throw std::runtime_error("unwind"); }
  catch (const std::exception& error) { std::cout << error.what() << values.size() << '\n'; }
}
EOF
for mode in dynamic static; do
  flags=()
  [[ "$mode" == static ]] && flags+=(-static)
  "$cc" "${flags[@]}" build/check/hello.c -o "build/check/c-$mode"
  "$cxx" "${flags[@]}" -std=c++20 -pthread build/check/hello.cpp -o "build/check/cxx-$mode"
done
# CMake's compiler detection must be able to link an executable with the SDK.
cat > build/check/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(sdk_check C CXX)
add_executable(hello hello.c)
add_executable(hello_cxx hello.cpp)
target_compile_features(hello_cxx PRIVATE cxx_std_20)
target_link_libraries(hello_cxx PRIVATE pthread)
EOF
cmake -G Ninja -S build/check -B build/check/cmake \
  -DCMAKE_TOOLCHAIN_FILE="$sdk/toolchain.cmake"
cmake --build build/check/cmake

for binary in build/check/c-{dynamic,static} build/check/cxx-{dynamic,static} "$rootfs/bin/toybox"; do
  "$readelf" -h -A "$binary"
  "$readelf" -h "$binary" | grep -q 'Machine:.*MIPS'
  dynamic=$("$readelf" -d "$binary")
  if printf '%s\n' "$dynamic" | grep -Eq 'NEEDED.*(libgcc|libstdc\+\+|ld-linux|libc\.so\.6)'; then
    echo "Unexpected GNU target dependency in $binary" >&2
    exit 1
  fi
done
for binary in build/check/c-dynamic build/check/cxx-dynamic; do
  "$readelf" -l "$binary" | grep -q '/lib/ld-musl-'
done
for binary in build/check/c-static build/check/cxx-static "$rootfs/bin/toybox"; do
  if "$readelf" -l "$binary" | grep -q INTERP; then
    echo "Expected static executable: $binary" >&2
    exit 1
  fi
done
for library in "$rootfs/usr/lib"/lib{c,unwind,c++abi,c++}.so*; do
  [[ -f "$library" ]] || continue
  "$readelf" -d "$library"
  if "$readelf" -d "$library" | grep -Eq 'NEEDED.*(libgcc|libstdc\+\+|libc\.so\.6)'; then
    echo "Unexpected GNU target dependency in $library" >&2
    exit 1
  fi
done
[[ -x "$rootfs/bin/sh" && -e "$rootfs/usr/lib/libc.a" ]]
for library in libunwind.a libc++abi.a libc++.a; do
  [[ -f "$rootfs/usr/lib/$library" ]]
done
for loader in "$rootfs"/lib/ld-musl-*.so.1; do
  [[ -f "$loader" ]]
done
printf 'Compile, link, ELF, and SDK relocation checks passed.\n'
