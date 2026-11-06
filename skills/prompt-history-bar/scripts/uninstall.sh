#!/usr/bin/env bash
# Compatibility wrapper; the uninstaller itself is install.py --uninstall.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd -P)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 was not found in PATH" >&2
  exit 1
fi
exec python3 "$DIR/install.py" --uninstall "$@"
