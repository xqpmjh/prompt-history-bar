#!/usr/bin/env python3
"""Safely add, replace, or remove the statusLine entry in settings.json.

The installer uses this instead of rewriting the whole file: existing bytes and
formatting stay intact, and only the statusLine value is touched. Every write
is validated and backed up first.

Exit codes: 0 changed or already correct, 2 usage, 3 conflict, 4 invalid settings.
"""

import json
import os
import re
import shutil
import sys
import tempfile
import time


def die(msg, code=4):
    print(msg, file=sys.stderr)
    sys.exit(code)


def detect_indent(raw):
    m = re.search(r"\n( +)\"", raw)
    if m:
        return max(2, min(8, len(m.group(1))))
    return 2


def load(raw):
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except ValueError as exc:
        die("settings.json is not valid JSON: %s" % exc)
    if not isinstance(data, dict):
        die("settings.json must contain a JSON object")
    return data


def value_end(text, start):
    """End index (exclusive) of the JSON value starting at `start`."""
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c in "{[":
                depth += 1
            elif c in "}]":
                depth -= 1
                if depth == 0:
                    return i + 1
            elif depth == 0 and c in ",}":
                return i
    return len(text)


def find_top_level(text, key):
    """(key_start, value_end) for a top-level object key, or None."""
    depth = 0
    in_str = False
    esc = False
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            j = i + 1
            esc = False
            while j < n:
                if esc:
                    esc = False
                elif text[j] == "\\":
                    esc = True
                elif text[j] == '"':
                    break
                j += 1
            if depth == 1:
                try:
                    token = json.loads(text[i:j + 1])
                except ValueError:
                    token = None
                if token == key:
                    k = j + 1
                    while k < n and text[k] in " \t\n\r":
                        k += 1
                    if k < n and text[k] == ":":
                        v = k + 1
                        while v < n and text[v] in " \t\n\r":
                            v += 1
                        return i, value_end(text, v)
            i = j + 1
            continue
        if c in "{[":
            depth += 1
        elif c in "}]":
            depth -= 1
        i += 1
    return None


def block(indent, command):
    pad = " " * indent
    inner = " " * (indent * 2)
    return ('"statusLine": {\n'
            '%s"type": "command",\n'
            '%s"command": %s\n'
            '%s}' % (inner, inner, json.dumps(command, ensure_ascii=False), pad))


def insert_block(raw, command):
    body = raw.rstrip()
    trailing = "\n" if raw.endswith("\n") else ""
    if not body.endswith("}"):
        die("settings.json does not end with an object")
    indent = detect_indent(raw)
    inner = body[:-1].rstrip()
    if inner.endswith("{"):
        prefix = inner + "\n"
    else:
        prefix = inner + ",\n"
    new = prefix + " " * indent + block(indent, command) + "\n}" + trailing
    return new


def replace_block(raw, command):
    found = find_top_level(raw, "statusLine")
    if not found:
        return insert_block(raw, command)
    start, end = found
    line_start = raw.rfind("\n", 0, start) + 1
    indent = len(raw[line_start:start]) - len(raw[line_start:start].lstrip(" "))
    new = raw[:start] + block(indent, command) + raw[end:]
    return new


def remove_block(raw):
    found = find_top_level(raw, "statusLine")
    if not found:
        return raw
    start, end = found
    # Remove the key/value and one adjacent comma, preferring the following one.
    rest = raw[end:]
    m = re.match(r"\s*,", rest)
    if m:
        return raw[:start] + rest[m.end():]
    before = raw[:start]
    m = re.search(r",\s*$", before)
    if m:
        return before[:m.start()] + rest
    return raw[:start] + rest


def backup(path):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = "%s.bak.%s" % (path, stamp)
    if os.path.exists(dest):
        n = 1
        while os.path.exists("%s-%d" % (dest, n)):
            n += 1
        dest = "%s-%d" % (dest, n)
    shutil.copy2(path, dest)
    return dest


def write_atomic(path, text):
    real = os.path.realpath(path)
    mode = os.stat(real).st_mode & 0o777 if os.path.exists(real) else 0o644
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".settings.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main():
    args = sys.argv[1:]
    if not args:
        die("usage: settings_helper.py --settings PATH --command CMD [--force] [--dry-run]\n"
            "       settings_helper.py --settings PATH --uninstall [--force] [--dry-run]", 2)
    settings = command = None
    force = dry = uninstall = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--settings" and i + 1 < len(args):
            settings = args[i + 1]; i += 2
        elif a == "--command" and i + 1 < len(args):
            command = args[i + 1]; i += 2
        elif a == "--force":
            force = True; i += 1
        elif a == "--dry-run":
            dry = True; i += 1
        elif a == "--uninstall":
            uninstall = True; i += 1
        else:
            die("unknown argument: %s" % a, 2)
    if not settings:
        die("--settings is required", 2)

    raw = ""
    if os.path.exists(settings):
        with open(settings, encoding="utf-8") as fh:
            raw = fh.read()
    data = load(raw)
    old = data.get("statusLine")
    old_cmd = old.get("command") if isinstance(old, dict) else None

    if uninstall:
        if old is None:
            print("statusLine is not set; nothing to do")
            return
        if old_cmd and "prompt-history-bar/statusline.py" not in old_cmd and not force:
            print("statusLine does not point to prompt-history-bar:\n  %s\n"
                  "re-run with --force to remove it anyway" % old_cmd, file=sys.stderr)
            sys.exit(3)
        new = remove_block(raw)
        check = json.loads(new)
        if {k: v for k, v in check.items() if k != "statusLine"} != \
           {k: v for k, v in data.items() if k != "statusLine"}:
            die("refusing to write: removing statusLine changed other settings")
        if dry:
            print("would remove statusLine from %s" % settings)
            return
        if not os.path.exists(settings):
            print("settings.json does not exist; nothing to do")
            return
        dest = backup(settings)
        write_atomic(settings, new)
        print("removed statusLine; backup at %s" % dest)
        return

    if not command:
        die("--command is required (or use --uninstall)", 2)
    if old_cmd == command:
        print("statusLine is already set to this command; no change")
        return
    if old_cmd and not force:
        print("statusLine already points to a different command:\n  %s" % old_cmd,
              file=sys.stderr)
        print("re-run with --force to replace it (a backup is kept)", file=sys.stderr)
        sys.exit(3)

    if old is None:
        new = insert_block(raw, command)
    else:
        new = replace_block(raw, command)
    check = json.loads(new)
    if {k: v for k, v in check.items() if k != "statusLine"} != \
       {k: v for k, v in data.items() if k != "statusLine"}:
        die("refusing to write: adding statusLine changed other settings")

    if dry:
        print("would set statusLine in %s:\n  %s" % (settings, command))
        return
    if os.path.exists(settings):
        dest = backup(settings)
    else:
        os.makedirs(os.path.dirname(settings), exist_ok=True)
        dest = None
    write_atomic(settings, new)
    print("statusLine set to:\n  %s" % command)
    if dest:
        print("backup at %s" % dest)


if __name__ == "__main__":
    main()