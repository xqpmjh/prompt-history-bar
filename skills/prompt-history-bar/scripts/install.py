#!/usr/bin/env python3
"""Install, update, or remove the Prompt History Bar status line.

This is the real installer; install.sh and uninstall.sh are thin wrappers kept
for compatibility. It exists so the skill still works when a distribution
channel drops shell scripts, and so it runs on machines without bash.
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

RUNTIME_REL = Path("statusline") / "prompt-history-bar"
COPY_RUNTIME = ("statusline.py", "history_bar.py", "settings_helper.py")
LANG_OPTIONS = ("en", "zh")

USAGE = """Prompt History Bar installer

Usage: install.py [options]

  --lang en|zh   Label language for ages (default: en)
  --paste        Show the first line of pasted content (default: off)
  --session      Show only the current session's prompts (default: whole directory)
  --refresh N    Also re-run the status line every N seconds (default: events only)
  --force        Replace an existing statusLine command (a backup is kept)
  --dry-run      Print the change without writing files
  --uninstall    Remove the statusLine entry installed by this tool
  --purge        With --uninstall, also delete the runtime copy
  -h, --help     Show this help

Files:
  runtime:  $CLAUDE_CONFIG_DIR/statusline/prompt-history-bar/
  settings: $CLAUDE_CONFIG_DIR/settings.json
"""


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def parse_args(argv: list[str]) -> dict:
    opts = {
        "lang": "en",
        "paste": False,
        "session": False,
        "refresh": None,
        "force": False,
        "dry_run": False,
        "uninstall": False,
        "purge": False,
    }
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg in ("-h", "--help"):
            print(USAGE, end="")
            raise SystemExit(0)
        elif arg == "--lang":
            if not args:
                fail("--lang needs a value", 2)
            opts["lang"] = args.pop(0)
        elif arg.startswith("--lang="):
            opts["lang"] = arg.split("=", 1)[1]
        elif arg == "--refresh":
            if not args:
                fail("--refresh needs a value", 2)
            opts["refresh"] = args.pop(0)
        elif arg.startswith("--refresh="):
            opts["refresh"] = arg.split("=", 1)[1]
        elif arg == "--paste":
            opts["paste"] = True
        elif arg == "--session":
            opts["session"] = True
        elif arg == "--force":
            opts["force"] = True
        elif arg == "--dry-run":
            opts["dry_run"] = True
        elif arg == "--uninstall":
            opts["uninstall"] = True
        elif arg == "--purge":
            opts["purge"] = True
        else:
            print("unknown option: %s" % arg, file=sys.stderr)
            print(USAGE, end="", file=sys.stderr)
            raise SystemExit(2)

    if opts["lang"] not in LANG_OPTIONS:
        fail("--lang must be en or zh", 2)

    refresh = opts["refresh"]
    if refresh is not None:
        if not refresh.isdigit():
            fail("--refresh must be a whole number of seconds >= 1", 2)
        if int(refresh) < 1:
            fail("--refresh must be a whole number of seconds >= 1", 2)
        opts["refresh"] = str(int(refresh))

    return opts


def build_command(python: str, script: Path, opts: dict) -> str:
    command = "%s %s" % (shlex.quote(python), shlex.quote(str(script)))
    if opts["lang"] != "en":
        command = "CLAUDE_HISTORY_LANG=%s %s" % (shlex.quote(opts["lang"]), command)
    if opts["paste"]:
        command = "CLAUDE_HISTORY_PASTE=1 " + command
    if opts["session"]:
        command = "CLAUDE_HISTORY_SCOPE=session " + command
    return command


def run_helper(helper: Path, settings: Path, opts: dict, extra: list[str]) -> int:
    args = [sys.executable, str(helper), "--settings", str(settings)]
    if opts["force"]:
        args.append("--force")
    if opts["dry_run"]:
        args.append("--dry-run")
    args.extend(extra)
    result = subprocess.run(args, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr, flush=True)
    return result.returncode


def copy_runtime(script_dir: Path, runtime_dir: Path) -> None:
    runtime_dir.mkdir(parents=True, exist_ok=True)
    for name in COPY_RUNTIME:
        source = script_dir / name
        target = runtime_dir / name
        if source.resolve() == target.resolve():
            continue
        shutil.copyfile(source, target)
    for name in ("uninstall.sh", "install.py"):
        source = script_dir / name
        if not source.is_file():
            continue
        target = runtime_dir / name
        if source.resolve() == target.resolve():
            continue
        shutil.copyfile(source, target)

    for name in ("statusline.py", "uninstall.sh", "install.py"):
        path = runtime_dir / name
        if path.is_file():
            path.chmod(0o755)
    for name in ("history_bar.py", "settings_helper.py"):
        path = runtime_dir / name
        if path.is_file():
            path.chmod(0o644)


def purge(runtime_dir: Path, config_dir: Path, dry_run: bool) -> None:
    expected = config_dir / RUNTIME_REL
    if runtime_dir.resolve() != expected.resolve():
        fail("refusing to purge unexpected path: %s" % runtime_dir)
    if dry_run:
        print("would remove %s" % runtime_dir)
        return
    if not (runtime_dir / "statusline.py").is_file():
        return
    trash = shutil.which("trash")
    if trash:
        result = subprocess.call([trash, str(runtime_dir)], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        if result == 0:
            print("removed %s" % runtime_dir)
            return
    shutil.rmtree(runtime_dir)
    print("removed %s" % runtime_dir)


def main(argv: list[str]) -> int:
    opts = parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))
    runtime_dir = config_dir / RUNTIME_REL
    settings = config_dir / "settings.json"

    helper = script_dir / "settings_helper.py"
    if not helper.is_file():
        helper = runtime_dir / "settings_helper.py"
    if not helper.is_file():
        fail("missing settings_helper.py")

    # Match what the shell installer recorded: the `python3` on PATH, not the
    # resolved binary, so re-running does not rewrite the statusLine command.
    python = shutil.which("python3") or sys.executable or "python3"

    if opts["uninstall"]:
        code = run_helper(helper, settings, opts, ["--uninstall"])
        if code != 0:
            return code
        if opts["purge"]:
            purge(runtime_dir, config_dir, opts["dry_run"])
        return 0

    for name in ("statusline.py", "history_bar.py"):
        if not (script_dir / name).is_file():
            fail("missing %s" % (script_dir / name))

    command = build_command(python, runtime_dir / "statusline.py", opts)
    extra = ["--command", command]
    if opts["refresh"] is not None:
        extra.extend(["--refresh", opts["refresh"]])

    if opts["dry_run"]:
        print("would install runtime to: %s" % runtime_dir, flush=True)
        return run_helper(helper, settings, opts, extra)

    copy_runtime(script_dir, runtime_dir)
    code = run_helper(helper, settings, opts, extra)
    if code != 0:
        return code

    try:
        data = json.loads(settings.read_text(encoding="utf-8"))
        if data.get("disableAllHooks") is True:
            print("warning: disableAllHooks is true; the status line will not run")
    except Exception:
        pass

    print()
    print("Next: start a new Claude Code session (or reload settings).")
    print("The status line is skipped until workspace trust is accepted.")
    print("History is read from %s; paste preview is %s."
          % (config_dir / "history.jsonl", "on" if opts["paste"] else "off"))
    return 0


if __name__ == "__main__":
    try:
        code = main(sys.argv[1:])
        sys.stdout.flush()
    except BrokenPipeError:
        # The reader (for example `| head` or `| grep -q`) went away first.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        code = 0
    raise SystemExit(code)
