#!/usr/bin/env bash
# Remove the Prompt History Bar status line entry (and optionally the runtime copy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
RUNTIME_DIR="$CONFIG_DIR/statusline/prompt-history-bar"
SETTINGS="$CONFIG_DIR/settings.json"
HELPER="$SCRIPT_DIR/settings_helper.py"
[ -f "$HELPER" ] || HELPER="$RUNTIME_DIR/settings_helper.py"

PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ]; then
  echo "python3 was not found in PATH" >&2
  exit 1
fi
if [ ! -f "$HELPER" ]; then
  echo "missing settings_helper.py" >&2
  exit 1
fi

ARGS=(--settings "$SETTINGS" --uninstall)
PURGE=0
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --dry-run) DRY=1; ARGS+=(--dry-run); shift ;;
    --force) ARGS+=(--force); shift ;;
    -h|--help)
      cat <<'EOF'
Remove the Prompt History Bar statusLine entry.

  --force     Remove it even if it no longer points at prompt-history-bar
  --dry-run   Print the change; write nothing
  --purge     Also delete the runtime copy
EOF
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

"$PYTHON" "$HELPER" "${ARGS[@]}"

if [ "$PURGE" = "1" ]; then
  if [ "$DRY" = "1" ]; then
    echo "would remove $RUNTIME_DIR"
    exit 0
  fi
  case "$RUNTIME_DIR" in
    "$CONFIG_DIR"/statusline/prompt-history-bar) ;;
    *) echo "refusing to purge unexpected path: $RUNTIME_DIR" >&2; exit 1 ;;
  esac
  if [ -f "$RUNTIME_DIR/statusline.py" ]; then
    if ! { command -v trash >/dev/null 2>&1 && trash "$RUNTIME_DIR" 2>/dev/null; }; then
      rm -rf -- "$RUNTIME_DIR"
    fi
    echo "removed $RUNTIME_DIR"
  fi
fi