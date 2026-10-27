#!/bin/zsh
# Shared build cache: keep the executable and its identity stable between runs.
set -euo pipefail
script_dir="${0:A:h}"
driver_name="${1:?Missing driver name}"
case "$driver_name" in
  HotkeyEscapeStress|TimedEscapeStress|MatrixEscapeStress|EditedCaptureChecks) ;;
  *) print -u2 'Unknown stress driver'; exit 2 ;;
esac
build_dir="$script_dir/.build"
mkdir -p "$build_dir"
source_file="$script_dir/$driver_name.swift"
permissions_file="$script_dir/StressDriverPermissions.swift"
binary="$build_dir/$driver_name"
if [[ ! -x "$binary" || "$source_file" -nt "$binary" || "$permissions_file" -nt "$binary" ]]; then
  xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$build_dir/modules" "$permissions_file" "$source_file" -o "$binary"
fi
print -r -- "$binary"
