#!/bin/zsh
# External UI test. --preflight and --request-permissions send no test inputs.
set -euo pipefail
script_dir="${0:A:h}"
binary="$(zsh "$script_dir/build-stress-driver.sh" HotkeyEscapeStress)"
exec "$binary" "$@"
