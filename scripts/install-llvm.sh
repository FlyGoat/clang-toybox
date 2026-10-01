#!/usr/bin/env bash
set -euo pipefail

# Use the unversioned DEVELOPMENT suite, rather than llvm.sh's stable default.
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_CODENAME" == noble ]]
sudo apt-get update
sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg
curl --fail --location --retry 5 https://apt.llvm.org/llvm-snapshot.gpg.key -o /tmp/llvm-snapshot.asc
gpg --batch --yes --dearmor -o /tmp/llvm-snapshot.gpg /tmp/llvm-snapshot.asc
sudo install -m 644 /tmp/llvm-snapshot.gpg /usr/share/keyrings/llvm-snapshot.gpg
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/llvm-snapshot.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble main' |
  sudo tee /etc/apt/sources.list.d/llvm-main.list >/dev/null
printf '%s\n' 'Package: *' 'Pin: origin "apt.llvm.org"' 'Pin-Priority: 700' |
  sudo tee /etc/apt/preferences.d/llvm-main >/dev/null
sudo apt-get update
# Meta-packages can lag a main-branch major bump. Discover the snapshot's
# versioned compiler from signed apt metadata, not from the clang meta-package.
major=$(apt-cache dumpavail | python3 -c '
import re, sys
versions = []
for record in sys.stdin.read().split("\n\n"):
    fields = dict(line.split(": ", 1) for line in record.splitlines() if ": " in line and not line.startswith(" "))
    match = re.fullmatch(r"clang-([0-9]+)", fields.get("Package", ""))
    if match and fields.get("Source", "").split()[0] == "llvm-toolchain-snapshot":
        versions.append(int(match[1]))
print(max(versions))
')
sudo apt-get install -y --no-install-recommends "clang-$major" "lld-$major" "llvm-$major" "llvm-$major-dev" \
  cmake ninja-build make python3 git xz-utils file rsync shellcheck

[[ "$major" =~ ^[0-9]+$ ]]
bindir="/usr/lib/llvm-$major/bin"
package_version=$(dpkg-query -W -f='${Version}' "clang-$major")
# Debian snapshot versions encode the upstream revision after the build date.
revision=$(printf '%s' "$package_version" | sed -nE 's/.*\+([0-9a-f]{7,40})-.*/\1/p')
[[ -n "$revision" ]] || { echo "Cannot determine LLVM source revision from $package_version" >&2; exit 1; }
source_ref=$(gh api "repos/llvm/llvm-project/commits/$revision" --jq .sha)
[[ "$source_ref" =~ ^[0-9a-f]{40}$ ]]
python3 -m pip install --user 'cmake>=3.31,<5'
printf '%s\n' "$HOME/.local/bin" >> "$GITHUB_PATH"
"$bindir/clang" --version
"$bindir/ld.lld" --version
printf 'LLVM_BINDIR=%s\nLLVM_MAJOR=%s\nLLVM_PACKAGE_VERSION=%s\nLLVM_SOURCE_REF=%s\n' \
  "$bindir" "$major" "$package_version" "$source_ref" >> "$GITHUB_ENV"
printf '%s\n' "$bindir" >> "$GITHUB_PATH"
printf 'source_ref=%s\n' "$source_ref" >> "$GITHUB_OUTPUT"
