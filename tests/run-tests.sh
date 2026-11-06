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
PROMPT_HASH="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
printf '[itdev@jsy19-118-23 ssl]$ make install\ninstalled\n' > "$CONFIG/paste-cache/$PROMPT_HASH.txt"
BAD_HASH="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
printf 'binary paste first line\n\xff\xfe broken\n' > "$CONFIG/paste-cache/$BAD_HASH.txt"

python3 - "$CONFIG/history.jsonl" "$PROJ" "$OTHER" "$PASTE_HASH" "$PROMPT_HASH" "$BAD_HASH" <<'PY'
import json
import sys
import time

path, proj, other, digest, prompt_digest, bad_digest = sys.argv[1:7]
now = int(time.time() * 1000)
rows = [
    (other, "other project prompt", {}),
    (proj, "second prompt: 中文测试 with a longer tail", {}),
    (proj, "[Pasted text #1 +2 lines] why does this fail", {"1": {"contentHash": digest}}),
    (proj, "[Pasted text #2 +2 lines]", {"2": {"contentHash": digest}}),
    (proj, "[Image #1]", {}),
    (proj, "[Image #2] check the layout", {}),
    (proj, "[Pasted text #3 +2 lines] deploy the box", {"3": {"contentHash": prompt_digest}}),
    (proj, "[Pasted text #4 +2 lines] binary paste", {"4": {"contentHash": bad_digest}}),
    (proj, "[root@host ~]# systemctl restart nginx", {}),
    (proj, "CPU% is high", {}),
    (proj, "~/proj on  main ❯ cargo test", {}),
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
PLAIN_OUT="$(printf '%s' "$SAMPLE" | CLAUDE_HISTORY_WIDTH=160 python3 "$SCRIPTS/statusline.py")"
check "paste preview is off by default" 'printf "%s" "$PLAIN_OUT" | grep -q "\[paste\]" && ! printf "%s" "$PLAIN_OUT" | grep -q "secret first line"'
PASTED_OUT="$(printf '%s' "$SAMPLE" | CLAUDE_HISTORY_WIDTH=160 CLAUDE_HISTORY_PASTE=1 python3 "$SCRIPTS/statusline.py")"
check "paste preview shows the first line when enabled" 'printf "%s" "$PASTED_OUT" | grep -q "secret first line"'

# A transcript pasted from a shell opens with the prompt line; that says nothing
# about intent, so the cell falls back to "[paste]" and keeps the typed text.
check "a shell-prompt first line is not used as a preview" 'printf "%s" "$PASTED_OUT" | grep -q "\[paste\] deploy the box" && ! printf "%s" "$PASTED_OUT" | grep -q "make install"'

# A cache file with invalid UTF-8 must not take the whole column down.
check "a non-UTF-8 paste cache does not break the bar" 'printf "%s" "$PASTED_OUT" | grep -q "binary paste"'

# A transcript pasted inline keeps the prompt line; the command is what matters.
check "a leading shell prompt is stripped from the display" 'printf "%s" "$PASTED_OUT" | grep -q "systemctl restart nginx" && ! printf "%s" "$PASTED_OUT" | grep -q "\[root@host"'
check "a starship prompt prefix is stripped inline" 'printf "%s" "$PASTED_OUT" | grep -q "cargo test" && ! printf "%s" "$PASTED_OUT" | grep -q "~/proj on"'
check "weak prompt-like text keeps its subject" 'printf "%s" "$PASTED_OUT" | grep -q "CPU% is high"'

# Prompt shapes: environment prefixes, Starship module lines, PowerShell and
# cmd, zsh's default `hostname%`. Bare `#`/`>`, prose arrows, host-like prose,
# and prose that merely quotes a glyph must stay text.
SHAPES="$(python3 - "$SCRIPTS/history_bar.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hb", sys.argv[1])
hb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hb)


def preview_hit(text):
    return hb.paste_first_line({"content": text}) == ""


def strip_hit(text):
    return hb.prompt_prefix_end(hb.clean(text)) > 0


preview_prompts = [
    "[itdev@host ssl]$ knt",
    "[root@host ~]# systemctl restart nginx",
    "itdev@host:~$ ls",
    "(base) itdev@host:~$ ls",
    "(venv) $ ls",
    "admin@host ~ $ ls",
    "$ ls",
    "macbook% ls",
    "PS> ls",
    "PS C:\\Users\\me> dir",
    "C:\\Users\\me>dir",
    "~/proj on  main \u276f ls",
    "~/proj on  main [!?] \u276f ls",
]
strip_prompts = [
    "[itdev@host ssl]$ knt",
    "[root@host ~]# systemctl restart nginx",
    "itdev@host:~$ ls",
    "(base) itdev@host:~$ ls",
    "(venv) $ ls",
    "admin@host ~ $ ls",
    "PS> ls",
    "PS C:\\Users\\me> dir",
    "C:\\Users\\me>dir",
    "~/proj on  main \u276f ls",
    "~/proj on  main [!?] \u276f ls",
]
others = [
    "100% done",
    "# Run a command through the SOCKS5 proxy",
    "> quoted line",
    "A \u2192 B",
    "user@host is down",
]
weak = ["$ ls", "macbook% ls", "\u03bb calculus"]
# A typed sentence can quote a prompt, glyph included; it keeps its head.
prose = [
    "\u9694\u58c1 \u72b6\u6001\u680f\u8fd8\u663e\u793a\u7740 \u201c\u276f \u00bb [itdev@host ssl]$ knt\u201c \u8fd9\u6837\u513f\u7684\u547d\u4ee4",
    "the bar shows \u276f commands",
]
bad = (
    [t for t in preview_prompts if not preview_hit(t)]
    + [t for t in strip_prompts if not strip_hit(t)]
    + [t for t in others if preview_hit(t)]
    + [t for t in weak if not preview_hit(t) or strip_hit(t)]
    + [t for t in prose if preview_hit(t) or strip_hit(t)]
)
print("ok" if not bad else repr(bad))
PY
)"
check "prompt shapes are recognised without over-matching" '[ "$SHAPES" = "ok" ]'

# Inputs that are only paste/image placeholders carry no intent and are skipped;
# image placeholders are stripped from entries that also have text.
check "paste-only and image-only inputs are skipped" '[ "$(printf "%s" "$PASTED_OUT" | grep -o "why does this fail\|check the layout" | wc -l | tr -d " ")" = "2" ] && ! printf "%s" "$PASTED_OUT" | grep -q "Image #"'
check "text next to a paste still shows" 'printf "%s" "$PASTED_OUT" | grep -q "why does this fail"'
check "image placeholder is dropped, text stays" 'printf "%s" "$PASTED_OUT" | grep -q "check the layout"'

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

# Parent fallback stops at the git root. A container directory without .git
# (like ~/Codes) must not lend its old prompts to a new project beneath it.
CONT="$WORK/container"
REPO="$WORK/repo"
mkdir -p "$CONT/newproj" "$REPO/.git" "$REPO/sub/deep"
python3 - "$CONFIG/history.jsonl" "$CONT" "$REPO" <<'PY'
import json
import sys
import time

path, cont, repo = sys.argv[1:4]
now = int(time.time() * 1000)
with open(path, "a", encoding="utf-8") as fh:
    for project, display in ((cont, "container old prompt"), (repo, "repo root prompt")):
        fh.write(json.dumps({"display": display, "project": project, "sessionId": "t",
                             "timestamp": now, "pastedContents": {}}) + "\n")
PY
CONT_OUT="$(python3 "$SCRIPTS/history_bar.py" "$CONT/newproj" 3)"
check "no-git parent does not leak into a new project" '! printf "%s" "$CONT_OUT" | grep -q "container old prompt"'
CONT_SELF="$(python3 "$SCRIPTS/history_bar.py" "$CONT" 3)"
check "no-git directory still shows its own history" 'printf "%s" "$CONT_SELF" | grep -q "container old prompt"'
REPO_OUT="$(python3 "$SCRIPTS/history_bar.py" "$REPO/sub/deep" 3)"
check "git subdirectory still falls back to the repo root" 'printf "%s" "$REPO_OUT" | grep -q "repo root prompt"'

# Two sessions in one directory: CLAUDE_HISTORY_SCOPE=session keeps them apart.
SESS="$WORK/sessproj"
mkdir -p "$SESS"
python3 - "$CONFIG/history.jsonl" "$SESS" <<'PY'
import json
import sys
import time

path, proj = sys.argv[1:3]
now = int(time.time() * 1000)
with open(path, "a", encoding="utf-8") as fh:
    for i, (sid, display) in enumerate((("sA", "task alpha one"), ("sB", "task beta one"),
                                        ("sA", "task alpha two"), ("sB", "task beta two"))):
        fh.write(json.dumps({"display": display, "project": proj, "sessionId": sid,
                             "timestamp": now + i, "pastedContents": {}}) + "\n")
PY
sess_run() {  # $1 = session id, rest = env assignments
  sid="$1"; shift
  printf '{"session_id":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Claude"}}' "$sid" "$SESS" \
    | env CLAUDE_HISTORY_WIDTH=140 "$@" python3 "$SCRIPTS/statusline.py"
}
SESS_ALL="$(sess_run sA)"
SESS_A="$(sess_run sA CLAUDE_HISTORY_SCOPE=session)"
SESS_B="$(sess_run sB CLAUDE_HISTORY_SCOPE=session)"
check "default scope shows every session in the directory" 'printf "%s" "$SESS_ALL" | grep -q "task alpha two" && printf "%s" "$SESS_ALL" | grep -q "task beta two"'
check "session scope shows only the current session" 'printf "%s" "$SESS_A" | grep -q "task alpha two" && ! printf "%s" "$SESS_A" | grep -q "task beta"'
check "session scope isolates the other session too" 'printf "%s" "$SESS_B" | grep -q "task beta two" && ! printf "%s" "$SESS_B" | grep -q "task alpha"'

# A prompt resent after a dropped connection shows once, at its newest time.
DUP="$WORK/dupproj"
mkdir -p "$DUP"
python3 - "$CONFIG/history.jsonl" "$DUP" <<'PY'
import json
import sys
import time

path, proj = sys.argv[1:3]
now = int(time.time() * 1000)
rows = [("far apart", {}), ("middle prompt", {}), ("far apart", {}),
        ("retry me please", {}), ("retry me please", {}),
        ("[Pasted text #1 +2 lines] go", {"1": {"id": 1, "type": "text", "content": "body A"}}),
        ("[Pasted text #1 +2 lines] go", {"1": {"id": 1, "type": "text", "content": "body B"}})]
with open(path, "a", encoding="utf-8") as fh:
    for i, (display, pastes) in enumerate(rows):
        fh.write(json.dumps({"display": display, "project": proj, "sessionId": "d1",
                             "timestamp": now + i, "pastedContents": pastes}) + "\n")
PY
DUP_OUT="$(python3 "$SCRIPTS/history_bar.py" "$DUP" 10)"
check "an adjacent repeat shows once" '[ "$(printf "%s" "$DUP_OUT" | grep -o "retry me please" | wc -l | tr -d " ")" = "1" ]'
check "a repeat separated by another input is kept" '[ "$(printf "%s" "$DUP_OUT" | grep -o "far apart" | wc -l | tr -d " ")" = "2" ]'
check "same placeholder with different paste content is kept" '[ "$(printf "%s" "$DUP_OUT" | grep -o "\[paste\] go" | wc -l | tr -d " ")" = "2" ]'

# Dropping `[Image #N]` also drops the separators and invisible characters it
# leaves at the front; a lone separator after an image carries no intent.
IMG="$WORK/imgproj"
mkdir -p "$IMG"
python3 - "$CONFIG/history.jsonl" "$IMG" <<'PY'
import json
import sys
import time

path, proj = sys.argv[1:3]
now = int(time.time() * 1000)
rows = ["[Image #1] ，有时候因为网络中断", "[Image #2] \u200b。 only after image",
        "[Image #3] ，", "?lead stays", "[Image #4] /resume now"]
with open(path, "a", encoding="utf-8") as fh:
    for i, display in enumerate(rows):
        fh.write(json.dumps({"display": display, "project": proj, "sessionId": "i1",
                             "timestamp": now + i, "pastedContents": {}}) + "\n")
PY
IMG_OUT="$(python3 "$SCRIPTS/history_bar.py" "$IMG" 10)"
check "separators after a dropped image placeholder are trimmed" 'printf "%s" "$IMG_OUT" | grep -q "❯ 有时候因为网络中断" && printf "%s" "$IMG_OUT" | grep -q "❯ only after image"'
check "an image followed only by punctuation is skipped" '[ "$(printf "%s" "$IMG_OUT" | grep -o "❯" | wc -l | tr -d " ")" = "4" ]'
check "punctuation is kept when no placeholder was dropped" 'printf "%s" "$IMG_OUT" | grep -q "❯ ?lead stays"'
check "a slash after an image is kept" 'printf "%s" "$IMG_OUT" | grep -q "❯ /resume now"'

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

check "--session adds the scope flag" 'bash "$SCRIPTS/install.sh" --dry-run --session | grep -q "CLAUDE_HISTORY_SCOPE=session"'
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

# --refresh writes refreshInterval next to the command.
check "--refresh shows in dry-run" 'bash "$SCRIPTS/install.sh" --dry-run --lang zh --paste --refresh 10 | grep -q "refreshInterval: 10"'
check "--refresh rejects non-numbers" '! bash "$SCRIPTS/install.sh" --dry-run --refresh abc >/dev/null 2>&1'
check "--refresh rejects 0" '! bash "$SCRIPTS/install.sh" --dry-run --refresh 0 >/dev/null 2>&1'
bash "$SCRIPTS/install.sh" --lang zh --paste --refresh 10 >/dev/null
check "--refresh sets refreshInterval without --force" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"statusLine\"][\"refreshInterval\"]==10
assert \"CLAUDE_HISTORY_LANG=zh\" in d[\"statusLine\"][\"command\"]
assert d[\"model\"]==\"sonnet\"
" "$CONFIG/settings.json"'
AFTER_R="$(shasum "$CONFIG/settings.json" | awk '{print $1}')"
bash "$SCRIPTS/install.sh" --lang zh --paste --refresh 10 >/dev/null
check "reinstall with --refresh is a no-op" '[ "$(shasum "$CONFIG/settings.json" | awk "{print \$1}")" = "$AFTER_R" ]'
bash "$SCRIPTS/install.sh" --lang zh --paste >/dev/null
check "dropping --refresh removes refreshInterval" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert \"refreshInterval\" not in d[\"statusLine\"]
" "$CONFIG/settings.json"'

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

# --- installer without the shell wrappers -------------------------------------
# Some distribution channels (ModelScope's npx install among them) drop *.sh
# files, so install.py has to work on its own.
NOSH="$WORK/nosh/scripts"
mkdir -p "$NOSH"
cp "$SCRIPTS"/*.py "$NOSH/"
printf '{"model": "sonnet"}\n' > "$CONFIG/settings.json"
CLAUDE_CONFIG_DIR="$CONFIG" python3 "$NOSH/install.py" --lang zh --paste >/dev/null
check "install.py works without the shell wrappers" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
c=d[\"statusLine\"][\"command\"]
assert \"CLAUDE_HISTORY_LANG=zh\" in c and \"CLAUDE_HISTORY_PASTE=1\" in c
assert d[\"model\"]==\"sonnet\"
" "$CONFIG/settings.json"'
check "install.py copies the runtime" '[ -f "$CONFIG/statusline/prompt-history-bar/install.py" ]'
check "install.py rejects --refresh 0" '! python3 "$NOSH/install.py" --dry-run --refresh 0 >/dev/null 2>&1'
CLAUDE_CONFIG_DIR="$CONFIG" python3 "$CONFIG/statusline/prompt-history-bar/install.py" --uninstall --purge >/dev/null
check "install.py --uninstall --purge from the runtime copy" '[ ! -e "$CONFIG/statusline/prompt-history-bar" ]'
check "install.py --uninstall removes statusLine" 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert \"statusLine\" not in d
assert d[\"model\"]==\"sonnet\"
" "$CONFIG/settings.json"'

# --- syntax -------------------------------------------------------------------
check "python files compile" 'python3 -m py_compile "$SCRIPTS/statusline.py" "$SCRIPTS/history_bar.py" "$SCRIPTS/settings_helper.py" "$SCRIPTS/install.py"'
check "shell files parse" 'bash -n "$SCRIPTS/install.sh" && bash -n "$SCRIPTS/uninstall.sh" && bash -n "$ROOT/tests/run-tests.sh"'

printf '\n%d passed, %d failed (work dir: %s)\n' "$pass" "$fail" "$WORK"
[ "$fail" -eq 0 ]