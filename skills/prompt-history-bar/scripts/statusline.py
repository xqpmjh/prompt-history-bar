#!/usr/bin/env python3
"""Claude Code status line: project/model/effort/context on the left, recent
prompts for the current project on the right.

Claude Code passes a JSON object on stdin. This script turns it into four left
rows and hands them to history_bar.render_statusline, which adds the right-side
column. Nothing is sent over the network.
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import history_bar  # noqa: E402


def _get(obj, *keys, default=None):
    cur = obj
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def short_path(cwd):
    home = os.path.expanduser("~")
    if cwd == home:
        return "~"
    if cwd.startswith(home + os.sep):
        return "~" + cwd[len(home):]
    return cwd


def git_branch(cwd):
    if not cwd or not os.path.isdir(cwd):
        return ""
    try:
        res = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=2,
            stdin=subprocess.DEVNULL,
        )
        if res.returncode == 0:
            return res.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def effort_level(payload):
    level = _get(payload, "effort", "level")
    if isinstance(level, str) and level:
        return level
    for key in ("CLAUDE_EFFORT", "CLAUDE_CODE_EFFORT_LEVEL"):
        val = os.environ.get(key)
        if val:
            return val
    return "high"


def context_text(payload):
    used = _get(payload, "context_window", "total_input_tokens")
    window = _get(payload, "context_window", "context_window_size")
    if not isinstance(used, (int, float)) or not isinstance(window, (int, float)):
        return ""
    if window <= 0:
        return ""
    denom = window
    try:
        compact = int(os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW") or 0)
    except ValueError:
        compact = 0
    if 0 < compact < denom:
        denom = compact
    return "compact:%.1fk/%.0fk (%.0f%%)" % (used / 1000.0, denom / 1000.0,
                                             used * 100.0 / denom)


def build_left(payload):
    cwd = (_get(payload, "workspace", "current_dir")
           or _get(payload, "workspace", "project_dir")
           or os.getcwd())
    model = _get(payload, "model", "display_name") or _get(payload, "model", "id") or "?"
    branch = git_branch(cwd)
    first = ("[%s] %s" % (branch, short_path(cwd))) if branch else short_path(cwd)
    return [first, str(model), "effort:%s" % effort_level(payload), context_text(payload)]


def preview(project):
    return {
        "model": {"display_name": "Claude"},
        "workspace": {"current_dir": project},
        "context_window": {"total_input_tokens": 42000, "context_window_size": 200000},
        "effort": {"level": "high"},
    }


def main():
    args = sys.argv[1:]
    if args and args[0] == "--preview":
        project = args[1] if len(args) > 1 else os.getcwd()
        payload = preview(project)
    else:
        try:
            payload = json.load(sys.stdin)
        except (ValueError, OSError):
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        project = (_get(payload, "workspace", "current_dir")
                   or _get(payload, "workspace", "project_dir")
                   or os.getcwd())
    lefts = build_left(payload)
    try:
        history_bar.render_statusline(lefts, project)
    except Exception:
        # A status line must never fail visibly; show the left column instead.
        if os.environ.get("DEBUG"):
            raise
        print("\n".join(lefts))


if __name__ == "__main__":
    main()