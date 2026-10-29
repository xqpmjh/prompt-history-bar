#!/usr/bin/env python3
"""Render recent prompts for the current project as a right-side status line column.

    history_bar.py --statusline <dir>   # read left lines from stdin, print full rows
    history_bar.py <dir> [count]        # single line for tmux status bars

Data source: <config>/history.jsonl, which Claude Code writes as you type.
The file is read backwards in blocks, so cost does not grow with its size.
If the exact project has no entries, parent directories are tried (up to four
levels, both the logical path and its realpath).

Paste previews are opt-in: set CLAUDE_HISTORY_PASTE=1 to read the first line of
pasted content from <config>/paste-cache. Otherwise a paste is shown as "[paste]".
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata

CONFIG_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
HIST = os.path.join(CONFIG_DIR, "history.jsonl")
PASTE_CACHE = os.path.join(CONFIG_DIR, "paste-cache")
PASTE_ENABLED = os.environ.get("CLAUDE_HISTORY_PASTE", "").lower() in ("1", "true", "yes")
LANG = os.environ.get("CLAUDE_HISTORY_LANG", "en").lower()
if LANG not in ("en", "zh"):
    LANG = "en"

SEG_WIDTH = 60
COL_GAP = 6
LEFT_GAP = 3
STYLE = os.environ.get("CLAUDE_HISTORY_STYLE", "\033[3;38;5;111m")
RESET = "\033[0m"
UP_LEVELS = 4
MIN_TWO_COL = 32
ANSI = re.compile(r"\x1b\[[0-9;]*m")
PASTED = re.compile(r"\[Pasted text #(\d+) \+\d+ lines\]")
IMAGE = re.compile(r"\s*\[Image #\d+\]")
CONTENT_HASH = re.compile(r"^[0-9a-f]{8,64}$")

META_WORDS = {"exit", "quit"}
# Built-ins that only change the UI or session state; their arguments are
# settings values, not conversation content. Skill commands (/wrapup, ...)
# are user intent and stay visible.
UI_CMDS = {
    "/effort", "/model", "/context", "/color", "/theme", "/tui", "/fast",
    "/statusline", "/output-style", "/permissions", "/config", "/rename",
    "/compact", "/clear", "/plugins", "/plugin", "/mcp", "/doctor", "/skills",
    "/help", "/status", "/tasks", "/reload-plugins", "/reload-skills",
}
# Only the bare command is a UI action; with text it is user intent
# (`/resume find that session`).
BARE_ONLY_UI = {"/resume", "/"}

LABELS = {
    "en": {"now": "now"},
    "zh": {"now": "刚刚"},
}


def disp_width(ch):
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(text):
    return sum(disp_width(ch) for ch in ANSI.sub("", text))


def fit(text, maxw):
    out, w = [], 0
    for ch in text:
        cw = disp_width(ch)
        if w + cw > maxw:
            break
        out.append(ch)
        w += cw
    return "".join(out)


def tmux_escape(text):
    return text.replace("#", "##")


def clean(text):
    text = text.replace("\r", " ").replace("\n", " ")
    text = "".join(ch if ch >= " " or ch == "\t" else " " for ch in text)
    return " ".join(text.split())


def paste_first_line(entry):
    """First non-empty line of a paste, or "" when it cannot be read.

    history.jsonl stores small pastes in `content` and large ones only as a
    `contentHash`; the body for the latter lives in paste-cache/<hash>.txt.
    """
    text = ""
    if isinstance(entry, dict):
        text = str(entry.get("content") or "")
        if not text:
            digest = entry.get("contentHash")
            if isinstance(digest, str) and CONTENT_HASH.match(digest):
                try:
                    with open(os.path.join(PASTE_CACHE, digest + ".txt")) as fh:
                        text = fh.read(4096)
                except OSError:
                    return ""
    for line in text.splitlines():
        line = clean(line)
        if line:
            return line
    return ""


def display_text(obj):
    """Replace `[Pasted text #N +M lines]` with a paste preview or "[paste]".

    `[Image #N]` placeholders are dropped; only the accompanying text stays."""
    raw = IMAGE.sub("", str(obj.get("display") or ""))
    if "[Pasted text" not in raw:
        return raw
    if not PASTE_ENABLED:
        return PASTED.sub("[paste]", raw)
    pastes = obj.get("pastedContents") or {}

    def sub(match):
        line = paste_first_line(pastes.get(match.group(1)))
        return "» " + line if line else match.group(0)

    return PASTED.sub(sub, raw)


def is_noise(display):
    """Bash-mode inputs (`!...`), UI settings commands, and exit words are not
    conversation content and do not take a history slot. Neither does an input
    that is only paste/image placeholders: a pasted command output starts with
    a shell prompt and shows no intent. With accompanying text it stays; the
    image placeholder is dropped in display_text()."""
    text = clean(str(display or ""))
    if not clean(IMAGE.sub("", PASTED.sub("", text))):
        return True
    if text.startswith("!"):
        return True
    if text in META_WORDS:
        return True
    words = text.split()
    if words[0] in UI_CMDS:
        return True
    return words[0] in BARE_ONLY_UI and len(words) == 1


def rel_age(ts_ms):
    d = max(0.0, time.time() - (ts_ms or 0) / 1000.0)
    if d < 60:
        return LABELS[LANG]["now"]
    if d < 3600:
        return "%dm" % int(d // 60)
    if d < 86400:
        return "%dh" % int(d // 3600)
    return "%dd" % int(d // 86400)


def scan_back(order, count):
    """One backwards pass over history.jsonl, returning {project: [entries]}.

    Stops early once the highest-priority directory has `count` entries, so
    the common case reads only the tail of the file.
    """
    found = dict((p, []) for p in order)

    def done():
        return len(found[order[0]]) >= count

    if not order or done():
        return found
    try:
        fh = open(HIST, "rb")
    except OSError:
        return found
    with fh:
        fh.seek(0, os.SEEK_END)
        pos = fh.tell()
        tail = b""

        def take(raw):
            try:
                obj = json.loads(raw)
            except ValueError:
                return False
            proj = obj.get("project")
            if (proj in found and len(found[proj]) < count
                    and not is_noise(obj.get("display"))):
                found[proj].append(obj)
            return done()

        while pos > 0:
            step = min(65536, pos)
            pos -= step
            fh.seek(pos)
            chunk = fh.read(step) + tail
            lines = chunk.split(b"\n")
            tail = lines[0]
            for raw in reversed(lines[1:]):
                if raw and take(raw):
                    return found
        if tail:
            take(tail)
    return found


def candidates(start):
    """Candidate directories from `start` upwards.

    Both the logical path and its realpath are walked: Claude records the
    logical cwd, and a session started through a symlinked directory would
    otherwise miss its own history.
    """
    home = os.path.expanduser("~")
    seen, out = set(), []
    for path in (os.path.abspath(start), os.path.realpath(start)):
        for _ in range(UP_LEVELS + 1):
            if path not in seen:
                seen.add(path)
                out.append(path)
            parent = os.path.dirname(path)
            if parent == path or path == home:
                break
            path = parent
    return out


def collect(start, count):
    cands = candidates(start)
    found = scan_back(cands, count)
    for cand in cands:
        if found.get(cand):
            return found[cand]
    return []


def build(entries, total=SEG_WIDTH):
    segs = []
    for obj in entries:
        if is_noise(obj.get("display")):
            continue
        text = clean(display_text(obj))
        if not text:
            continue
        age = rel_age(obj.get("timestamp"))
        # Prefix "❯ " (2 cells), separator " · " (3), and the age also take space.
        budget = total - 2 - 3 - text_width(age)
        segs.append("❯ " + fit(text, max(1, budget)) + " · " + age)
    return segs


def _state_dir():
    """Private state directory (0700), avoiding a predictable /tmp path."""
    path = os.path.join(tempfile.gettempdir(),
                        "claude-history-bar-%d" % os.getuid())
    try:
        if os.path.islink(path) or (os.path.exists(path) and not os.path.isdir(path)):
            return None
        os.makedirs(path, mode=0o700, exist_ok=True)
        if os.lstat(path).st_uid != os.getuid():
            return None
    except OSError:
        return None
    return path


def _session_key():
    """Width cache is per pane/session; one window must not reuse another's."""
    raw = (os.environ.get("TMUX_PANE") or os.environ.get("ITERM_SESSION_ID")
           or os.environ.get("TERM_SESSION_ID") or "default")
    return re.sub(r"[^A-Za-z0-9_.-]", "_", raw)


def _note(width, source):
    """With DEBUG=1, append each render's width source under the state dir."""
    if not os.environ.get("DEBUG"):
        return
    path = _state_dir()
    if not path:
        return
    try:
        with open(os.path.join(path, "debug.log"), "a") as fh:
            fh.write("%s %s width=%s source=%s\n"
                     % (time.strftime("%Y-%m-%d %H:%M:%S"), _session_key(),
                        width, source))
    except OSError:
        pass


def _cache_path():
    path = _state_dir()
    return os.path.join(path, "width-" + _session_key()) if path else None


def _cached_width():
    path = _cache_path()
    if not path:
        return 0
    try:
        with open(path) as fh:
            width = int(fh.read().strip())
    except (OSError, ValueError):
        return 0
    return width if 0 < width < 4096 else 0


def _remember_width(width):
    path = _cache_path()
    if not path:
        return
    try:
        with open(path, "w") as fh:
            fh.write(str(width))
    except OSError:
        pass


def tty_width():
    """Width of the controlling terminal, when the status line process has one."""
    try:
        fd = os.open("/dev/tty", os.O_RDONLY | getattr(os, "O_NOCTTY", 0))
    except OSError:
        return 0
    try:
        import fcntl
        import struct
        import termios
        data = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        cols = struct.unpack("HHHH", data)[1]
        return cols if cols > 0 else 0
    except (OSError, ImportError, ValueError):
        return 0
    finally:
        os.close(fd)


def pane_width():
    """Terminal width: forced, tmux, COLUMNS, /dev/tty, cached, then 120."""
    import shutil

    forced = os.environ.get("CLAUDE_HISTORY_WIDTH")
    if forced:
        try:
            forced_w = int(forced)
            if forced_w > 0:
                _note(forced_w, "env")
                return forced_w
        except ValueError:
            pass

    pane = os.environ.get("TMUX_PANE")
    in_tmux = bool(pane or os.environ.get("TMUX"))
    exes = [shutil.which("tmux"), "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
    variants = []
    if pane:
        variants.append(["-t", pane])
    if in_tmux:
        # Without TMUX_PANE fall back to the current client, but only when
        # actually inside tmux; otherwise this returns another pane's width.
        variants.append([])
    for exe in exes:
        if not exe or not os.path.exists(exe):
            continue
        for fmt in ("#{pane_width}", "#{client_width}"):
            for extra in variants:
                try:
                    res = subprocess.run(
                        [exe, "display-message", "-p"] + extra + [fmt],
                        capture_output=True, text=True, timeout=3,
                        stdin=subprocess.DEVNULL,
                    )
                    width = int(res.stdout.strip())
                    if width > 0:
                        _remember_width(width)
                        _note(width, "tmux %s %s" % (fmt, " ".join(extra) or "-"))
                        return width
                except (OSError, ValueError, subprocess.SubprocessError):
                    continue

    try:
        width = int(os.environ.get("COLUMNS") or 0)
    except ValueError:
        width = 0
    if width > 0:
        _note(width, "COLUMNS")
        return width

    width = tty_width()
    if width > 0:
        _remember_width(width)
        _note(width, "tty")
        return width

    cached = _cached_width()
    if cached:
        _note(cached, "cached")
        return cached
    _note(120, "default")
    return 120


def clamp(text, maxw):
    if text_width(text) <= maxw:
        return text
    return fit(text, maxw - 1) + "…"


def pad_to(text, target):
    return text + " " * max(0, target - text_width(text))


def middle_elide(text, maxw):
    """Keep the head and tail, elide the middle; best for paths."""
    if text_width(text) <= maxw:
        return text
    if maxw < 14:
        return fit(ANSI.sub("", text), maxw)
    # Strip color before slicing so an SGR sequence cannot be cut in half.
    text = ANSI.sub("", text)
    if text_width(text) <= maxw:
        return text
    head = fit(text, 12)
    keep = maxw - text_width(head) - 1
    tail, w = [], 0
    for ch in reversed(text):
        cw = disp_width(ch)
        if w + cw > keep:
            break
        tail.append(ch)
        w += cw
    return head + "…" + "".join(reversed(tail))


def render_statusline(lefts, project):
    """Print `lefts` (one list item per row) with the history column on the right."""
    while lefts and not lefts[-1]:
        lefts.pop()
    if not lefts:
        return

    rows = len(lefts)
    width = pane_width()
    # Left column takes at most a third of the pane, capped at 45 cells.
    limit = max(16, min(45, width // 3))
    lefts = [middle_elide(left, limit) for left in lefts]

    entries = collect(project, rows * 2)
    if not entries:
        print("\n".join(lefts))
        return

    max_left = max(text_width(left) for left in lefts)
    avail = width - max_left - LEFT_GAP
    two_col = len(entries) > rows

    if two_col:
        col_w = min(SEG_WIDTH, (avail - COL_GAP) // 2)
        if col_w < MIN_TWO_COL:
            # Two columns narrower than a readable third each: fall back to one.
            two_col = False
            col_w = min(SEG_WIDTH, avail)
    else:
        col_w = min(SEG_WIDTH, avail)
    if col_w < 12:
        print("\n".join(lefts))
        return

    segs = build(entries, col_w)
    segs.reverse()  # oldest first, newest at the bottom
    col1 = segs[:rows]
    col2 = segs[rows:rows * 2] if two_col else []
    start = width - (col_w * 2 + COL_GAP if two_col else col_w)

    def styled(cell):
        return STYLE + cell + RESET if cell else ""

    out = []
    for i, left in enumerate(lefts):
        gap = start - text_width(left)
        if gap < 1:
            out.append(left)
            continue
        cell1 = clamp(col1[i], col_w) if i < len(col1) else ""
        cell2 = clamp(col2[i], col_w) if i < len(col2) else ""
        buf = left + " " * gap + styled(cell1)
        if two_col:
            buf = pad_to(buf, start + col_w + COL_GAP) + styled(cell2)
        out.append(buf)
    print("\n".join(out))


def statusline(project):
    lefts = sys.stdin.read().split("\n")
    render_statusline(lefts, project)


def tmux_line(project, count):
    segs = build(collect(project, count))
    print(tmux_escape("    │    ".join(segs)) if segs else "")


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "--statusline":
        statusline(argv[1] if len(argv) > 1 else os.getcwd())
        return
    try:
        count = int(argv[1]) if len(argv) > 1 else 2
    except ValueError:
        count = 2
    tmux_line(argv[0] if argv else os.getcwd(), max(1, count))


if __name__ == "__main__":
    main()