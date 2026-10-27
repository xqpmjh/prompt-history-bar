#!/usr/bin/env bash
# Dependency-free checks for the Prompt History Bar package.
# Everything runs under a throwaway HOME; the real ~/.claude is never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPTS="$ROOT/skills/prompt-history-bar/scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/phb-test.XXXXXX")"
HOME_DIR="$WORK/home"
PROJ="$WORK/project"
OTHER="$WORK/other"
CONFIG="$HOME_DIR/.claude"
mkdir -p "$CONFIG/paste-cache" "$PROJ" "$OTHER"

export HOME="$HOME_DIR"
unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE COLUMNS CLAUDE_HISTORY_STYLE
unset CLAUDE_HISTORY_LANG CLAUDE_HISTORY_PASTE CLAUDE_HISTORY_WIDTH

pass=0
fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

PASTE_HASH="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf 'secret first line\nsecond line\n' > "$CONFIG/paste-cache/$PASTE_HASH.txt"

python3 - "$CONFIG/history.jsonl" "$PROJ" "$OTHER" "$PASTE_HASH" <<'PY'
import json
import sys
import time

path, proj, other, digest = sys.argv[1:5]
now = int(time.time() * 1000)
rows = [
    (other, "other project prompt", {}),
    (proj, "first prompt in project", {}),
    (proj, "second prompt: 中文测试 with a longer tail", {}),
    (proj, "[Pasted text #1 +2 lines]", {"1": {"contentHash": digest}}),
    (proj, "newest prompt", {}),
]
with open(path, "w", encoding="utf-8") as fh:
    for i, (project, display, pastes) in enumerate(rows):
        fh.write(json.dumps({
            "display": display,
            "project": project,
            "sessionId": "test",
            "timestamp": now - (len(rows) - 1 - i) * 60000,
            "pastedContents": pastes,
        }, ensure_ascii=False) + "\n")
PY

SAMPLE="$(python3 - "$PROJ" <<'PY'
import json
import sys
print(json.dumps({
    "model": {"display_name": "Claude"},
    "workspace": {"current_dir": sys.argv[1]},
    "context_window": {"total_input_tokens": 42000, "context_window_size": 200000},
    "effort": {"level": "high"},
}))
PY
)"

render() {
  printf '%s' "$SAMPLE" | CLAUDE_HISTORY_WIDTH=100 python3 "$SCRIPTS/statusline.py"
}

# --- rendering ---------------------------------------------------------------
OUT="$(render)"
check "renders four rows" '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = "4" ]'
check "shows the newest project prompt" 'printf "%s" "$OUT" | grep -q "newest prompt"'
check "does not show another project's prompt" '! printf "%s" "$OUT" | grep -q "other project prompt"'
check "width stays at or below 100 cells" 'printf "%s" "$OUT" | python3 -c "
import sys, unicodedata, re
ansi = re.compile(r\"\x1b\[[0-9;]*m\")
for line in sys.stdin.read().splitlines():
    w = sum(2 if unicodedata.east_asian_width(c) in (\"W\", \"F\") else 1 for c in ansi.sub(\"\", line))
    assert w <= 100, (w, line)
"'
COLUMNS_OUT="$(printf '%s' "$SAMPLE" | COLUMNS=40 python3 "$SCRIPTS/statusline.py")"
check "uses COLUMNS when tmux is absent" 'printf "%s" "$COLUMNS_OUT" | python3 -c "
import sys, unicodedata, re
ansi = re.compile(r\"\x1b\[[0-9;]*m\")
for line in sys.stdin.read().splitlines():
    w = sum(2 if unicodedata.east_asian_width(c) in (\"W\", \"F\") else 1 for c in ansi.sub(\"\", line))
    assert w <= 40, (w, line)
"'
check "english labels by default" 'printf "%s" "$OUT" | grep -Eq " · (now|[0-9]+m|[0-9]+h|[0-9]+d)"'
check "chinese labels with CLAUDE_HISTORY_LANG=zh" 'printf "%s" "$SAMPLE" | CLAUDE_HISTORY_WIDTH=100 CLAUDE_HISTORY_LANG=zh python3 "$SCRIPTS/statusline.py" | grep -q "刚刚"'

# Paste preview is opt-in.
check "paste preview is off by default" 'printf "%s" "$OUT" | grep -q "\[paste\]" && ! printf "%s" "$OUT" | grep -q "secret first line"'
PASTED_OUT="$(printf '%s' "$SAMPLE" | CLAUDE_HISTORY_WIDTH=100 CLAUDE_HISTORY_PASTE=1 python3 "$SCRIPTS/statusline.py")"
check "paste preview shows the first line when enabled" 'printf "%s" "$PASTED_OUT" | grep -q "secret first line"'

# No matching history: left column only.
NOHIST="$WORK/nohistory"
mkdir -p "$NOHIST"
NOHIST_SAMPLE="$(python3 - "$NOHIST" <<'PY'
import json
import sys
print(json.dumps({
    "model": {"display_name": "Claude"},
    "workspace": {"current_dir": sys.argv[1]},
    "context_window": {"total_input_tokens": 42000, "context_window_size": 200000},
    "effort": {"level": "high"},
}))
PY
)"
EMPTY_OUT="$(printf '%s' "$NOHIST_SAMPLE" | CLAUDE_HISTORY_WIDTH=100 python3 "$SCRIPTS/statusline.py")"
check "no history still prints the four left rows" '[ "$(printf "%s\n" "$EMPTY_OUT" | wc -l | tr -d " ")" = "4" ] && printf "%s" "$EMPTY_OUT" | grep -q "effort:high" && ! printf "%s" "$EMPTY_OUT" | grep -q "❯"'

# --- install / uninstall ------------------------------------------------------
cat > "$CONFIG/settings.json" <<'JSON'
{
  "model": "sonnet",
  "permissions": {
    "allow": ["Bash(ls:*)"]
  }
}
JSON
BEFORE="$(shasum "$CONFIG/settings.json" | awk '{print $1}')"
bash "$SCRIPTS/install.sh" --dry-run --lang zh >/dev/null
check "dry-run does not change settings" '[ "$(shasum "$CONFIG/settings.json" | awk "{print \$1}")" = "$BEFORE" ]'

bash "$SCRIPTS/install.sh" --lang zh --paste >/dev/null
check "install sets statusLine" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
c=d[\"statusLine\"][\"command\"]
assert \"CLAUDE_HISTORY_LANG=zh\" in c and \"CLAUDE_HISTORY_PASTE=1\" in c
assert \"prompt-history-bar/statusline.py\" in c
" "$CONFIG/settings.json"'
check "install keeps other settings" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"model\"]==\"sonnet\"
assert d[\"permissions\"][\"allow\"]==[\"Bash(ls:*)\"]
" "$CONFIG/settings.json"'
check "install creates a backup" 'ls "$CONFIG"/settings.json.bak.* >/dev/null 2>&1'
check "install copies the runtime" '[ -f "$CONFIG/statusline/prompt-history-bar/statusline.py" ]'
INSTALLED_OUT="$(printf '%s' "$SAMPLE" | CLAUDE_HISTORY_WIDTH=100 python3 "$CONFIG/statusline/prompt-history-bar/statusline.py")"
check "installed runtime renders history" 'printf "%s" "$INSTALLED_OUT" | grep -q "newest prompt"'

AFTER="$(shasum "$CONFIG/settings.json" | awk '{print $1}')"
bash "$SCRIPTS/install.sh" --lang zh --paste >/dev/null
check "reinstall is a no-op" '[ "$(shasum "$CONFIG/settings.json" | awk "{print \$1}")" = "$AFTER" ]'

# Replacing an existing statusLine (the local migration path).
python3 - "$CONFIG/settings.json" <<'PY'
import json
import sys
p = sys.argv[1]
d = json.load(open(p))
d["statusLine"] = {"type": "command", "command": "bash /old/statusline.sh"}
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
PY
bash "$SCRIPTS/install.sh" --lang zh --paste --force >/dev/null
check "force replaces an existing statusLine" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert \"prompt-history-bar/statusline.py\" in d[\"statusLine\"][\"command\"]
assert d[\"model\"]==\"sonnet\"
" "$CONFIG/settings.json"'
if [ "$(grep -c '"statusLine"' "$CONFIG/settings.json")" = "1" ]; then
  ok "force keeps exactly one statusLine key"
else
  no "force keeps exactly one statusLine key"
fi

bash "$CONFIG/statusline/prompt-history-bar/uninstall.sh" --purge >/dev/null
check "uninstall removes statusLine" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert \"statusLine\" not in d
assert d[\"model\"]==\"sonnet\"
assert d[\"permissions\"][\"allow\"]==[\"Bash(ls:*)\"]
" "$CONFIG/settings.json"'
check "uninstall --purge removes the runtime copy" '[ ! -e "$CONFIG/statusline/prompt-history-bar" ]'

# --- syntax -------------------------------------------------------------------
check "python files compile" 'python3 -m py_compile "$SCRIPTS/statusline.py" "$SCRIPTS/history_bar.py" "$SCRIPTS/settings_helper.py"'
check "shell files parse" 'bash -n "$SCRIPTS/install.sh" && bash -n "$SCRIPTS/uninstall.sh" && bash -n "$ROOT/tests/run-tests.sh"'

printf '\n%d passed, %d failed (work dir: %s)\n' "$pass" "$fail" "$WORK"
[ "$fail" -eq 0 ]