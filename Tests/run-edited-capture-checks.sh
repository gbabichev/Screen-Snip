#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
binary="$(zsh "$script_dir/build-stress-driver.sh" EditedCaptureChecks)"
exec "$binary" "$@"
