#!/usr/bin/env bash
set -euo pipefail
: "${PROFILE:?}"
bundle="clang-toybox-$PROFILE"
epoch=$(git show -s --format=%ct HEAD)
XZ_OPT='-T2 -6' tar --sort=name --mtime="@$epoch" --owner=0 --group=0 \
  --numeric-owner -cJf "out/$bundle.tar.xz" -C out "$bundle"
(
  cd out
  sha256sum "$bundle.tar.xz" > "$bundle.tar.xz.sha256"
)
{
  printf '### %s\n\n' "$PROFILE"
  printf 'Combined rootfs and SDK: %s.tar.xz\n\n' "$bundle"
  printf '```json\n'
  cat "out/$bundle/manifest.json"
  printf '```\n'
} >> "$GITHUB_STEP_SUMMARY"
