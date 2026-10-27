#!/usr/bin/env bash
# Install, update, or remove the Prompt History Bar status line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
RUNTIME_DIR="$CONFIG_DIR/statusline/prompt-history-bar"
SETTINGS="$CONFIG_DIR/settings.json"
HELPER="$SCRIPT_DIR/settings_helper.py"

LANG_OPT="en"
PASTE_OPT=0
FORCE=0
DRY=0
UNINSTALL=0
PURGE=0

usage() {
  cat <<'EOF'
Prompt History Bar installer

Usage: install.sh [options]

  --lang en|zh   Label language for ages (default: en)
  --paste        Show the first line of pasted content (default: off)
  --force        Replace an existing statusLine command (a backup is kept)
  --dry-run      Print the change without writing files
  --uninstall    Remove the statusLine entry installed by this tool
  --purge        With --uninstall, also delete the runtime copy
  -h, --help     Show this help

Files:
  runtime:  $CLAUDE_CONFIG_DIR/statusline/prompt-history-bar/
  settings: $CLAUDE_CONFIG_DIR/settings.json
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --lang)
      [ $# -ge 2 ] || { echo "--lang needs a value" >&2; exit 2; }
      LANG_OPT="$2"; shift 2 ;;
    --lang=*)
      LANG_OPT="${1#*=}"; shift ;;
    --paste) PASTE_OPT=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$LANG_OPT" in
  en|zh) ;;
  *) echo "--lang must be en or zh" >&2; exit 2 ;;
esac

PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ]; then
  echo "python3 was not found in PATH" >&2
  exit 1
fi

if [ ! -f "$HELPER" ]; then
  echo "missing $HELPER" >&2
  exit 1
fi

HELPER_ARGS=(--settings "$SETTINGS")
[ "$FORCE" = "1" ] && HELPER_ARGS+=(--force)
[ "$DRY" = "1" ] && HELPER_ARGS+=(--dry-run)

if [ "$UNINSTALL" = "1" ]; then
  "$PYTHON" "$HELPER" "${HELPER_ARGS[@]}" --uninstall
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
  exit 0
fi

for f in statusline.py history_bar.py; do
  if [ ! -f "$SCRIPT_DIR/$f" ]; then
    echo "missing $SCRIPT_DIR/$f" >&2
    exit 1
  fi
done

COMMAND="$("$PYTHON" - "$PYTHON" "$RUNTIME_DIR/statusline.py" "$LANG_OPT" "$PASTE_OPT" <<'PY'
import shlex
import sys

python, script, lang, paste = sys.argv[1:5]
cmd = "%s %s" % (shlex.quote(python), shlex.quote(script))
if lang != "en":
    cmd = "CLAUDE_HISTORY_LANG=%s %s" % (shlex.quote(lang), cmd)
if paste == "1":
    cmd = "CLAUDE_HISTORY_PASTE=1 " + cmd
print(cmd)
PY
)"

if [ "$DRY" = "1" ]; then
  echo "would install runtime to: $RUNTIME_DIR"
  "$PYTHON" "$HELPER" "${HELPER_ARGS[@]}" --command "$COMMAND"
  exit $?
fi

mkdir -p "$RUNTIME_DIR"
cp -f "$SCRIPT_DIR/statusline.py" "$RUNTIME_DIR/statusline.py"
cp -f "$SCRIPT_DIR/history_bar.py" "$RUNTIME_DIR/history_bar.py"
cp -f "$SCRIPT_DIR/settings_helper.py" "$RUNTIME_DIR/settings_helper.py"
cp -f "$SCRIPT_DIR/uninstall.sh" "$RUNTIME_DIR/uninstall.sh"
chmod 755 "$RUNTIME_DIR/statusline.py" "$RUNTIME_DIR/uninstall.sh"
chmod 644 "$RUNTIME_DIR/history_bar.py" "$RUNTIME_DIR/settings_helper.py"

"$PYTHON" "$HELPER" "${HELPER_ARGS[@]}" --command "$COMMAND"

"$PYTHON" - "$SETTINGS" <<'PY' || true
import json
import sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
if data.get("disableAllHooks") is True:
    print("warning: disableAllHooks is true; the status line will not run")
PY

echo
echo "Next: start a new Claude Code session (or reload settings)."
echo "The status line is skipped until workspace trust is accepted."
echo "History is read from $CONFIG_DIR/history.jsonl; paste preview is $( [ "$PASTE_OPT" = "1" ] && echo on || echo off )."