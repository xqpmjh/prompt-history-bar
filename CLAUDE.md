# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Prompt History Bar adds a right-side column of recent prompts to the Claude Code status line. This repository is the only place the feature is developed. The copy under `~/.claude/statusline/prompt-history-bar/` is a runtime install that `install.sh` copies verbatim; never edit it by hand.

## Commands

```bash
bash tests/run-tests.sh        # full suite; throwaway HOME, real ~/.claude untouched
claude plugin validate .       # manifest/skill check; passes today
```

- The suite is one bash script with no per-test filter. To iterate on one behavior, run the whole suite (it prints `FAIL <name>` and the work dir path) or render by hand:

  ```bash
  python3 skills/prompt-history-bar/scripts/statusline.py --preview "$PWD"
  printf '%s' '{"workspace":{"current_dir":"'"$PWD"'"},"model":{"display_name":"Claude"}}' \
    | CLAUDE_HISTORY_WIDTH=100 python3 skills/prompt-history-bar/scripts/statusline.py
  ```

  `CLAUDE_HISTORY_WIDTH` pins the width; `DEBUG=1` logs the width source and re-raises render exceptions instead of falling back.
- Syntax gates live inside the suite: `python3 -m py_compile` on the three Python files and `bash -n` on `install.sh`, `uninstall.sh`, and `tests/run-tests.sh`.
- `claude plugin validate . --strict` currently fails on a warning that a root `CLAUDE.md` is not recognised as plugin content (it is developer context). Use non-strict validation unless the packaging decision changes.

## Architecture

Two entry points, one renderer, one settings writer.

`statusline.py` is what Claude Code runs on every refresh: stdin JSON → `build_left` → `history_bar.render_statusline` → stdout. `history_bar.py` also runs standalone as a one-line tmux status bar (`history_bar.py <dir> [count]`, with `#` escaped). `install.sh` and `uninstall.sh` are the only things that write installation state: `install.sh` copies the four scripts into `$CLAUDE_CONFIG_DIR/statusline/prompt-history-bar/` and has `settings_helper.py` put the command into `settings.json`; `uninstall.sh` removes it through the same helper.

Invariants worth preserving:

- **The status line must never fail visibly or overflow.** `statusline.py` catches any render exception and prints the left rows alone (`DEBUG=1` re-raises). Every layout branch clamps to the pane width; CJK cells count as 2 (`east_asian_width`).
- **History scanning must stay incremental.** `history.jsonl` grows without bound and is read on every refresh. `scan_back` reads 64 KiB blocks from the end and stops once the first candidate directory has `rows * 2` entries. Do not load or sort the whole file.
- **Project matching is tolerant by design.** Candidates are the logical path and its realpath, each walked up four parents without going above `$HOME`; the first directory with entries wins. Symlinked workspaces depend on the realpath leg.
- **Filtering is what keeps the bar useful.** `is_noise` drops bash inputs (`!...`), UI-only slash commands (`UI_CMDS`), bare `/resume` and `/`, `exit`/`quit`, inputs that are only paste/image placeholders, and displays that are only a prompt. Skill commands stay: they are user intent. An inline-pasted transcript keeps its command, with a strong leading prompt stripped in `build` via `prompt_prefix_end` (bare `$`/`%` would eat prose). When Claude Code gains a settings-only command, add it to `UI_CMDS` or `BARE_ONLY_UI`.
- **Paste preview is opt-in.** History stores small pastes inline in `pastedContents[N].content`, large ones only as `contentHash` pointing at `<config>/paste-cache/<hash>.txt`. Without `CLAUDE_HISTORY_PASTE=1` the bar prints `[paste]` and never opens the cache. With it on, the preview is the paste's first line unless the line matches `PROMPT` (host/bracket prompts, `$`/`%`, `hostname%`, PowerShell/cmd, `(venv)` prefixes) or `STARSHIP` (a `dir on branch ❯` module line); bare `#` and `>` are deliberately not prompt signals. The cache is read with `errors="replace"` so one bad byte cannot blank the column.
- **Width comes from a fallback chain**, because the status line JSON has no terminal size: `CLAUDE_HISTORY_WIDTH` → tmux (`TMUX_PANE`) → `COLUMNS` → `/dev/tty` ioctl → per-session cached width → 120. Cache and debug log live in `${TMPDIR}/claude-history-bar-<uid>` (mode 0700).

Layout: the left column is capped at `max(16, min(45, width // 3))`. The history column is right-aligned to the pane edge, uses two columns only when there are more entries than left rows and each column is at least 32 cells (max 60, gap 6), then one column, then the left rows alone below 12 cells. When the two-column layout is rejected, the one-column fallback keeps the newest entries.

`settings_helper.py` splices only the `statusLine` key in the raw text so the user's formatting survives, re-parses the result, and refuses to write if any other key changed. It backs up to `settings.json.bak.<stamp>` and is idempotent when the command is unchanged. Exit codes: 2 usage, 3 conflict (needs `--force`), 4 invalid settings. `uninstall.sh` removes only that key; `--purge` sends the runtime copy to `trash` when available.

## Docs that restate behavior

`README.md`, `skills/prompt-history-bar/SKILL.md`, and `SUBMISSION.md` each describe the options, the privacy table, and "How it works". A behavior change needs matching edits in `README.md` and `SKILL.md`; touch `SUBMISSION.md` only for data access, network, or packaging changes. The plugin version is duplicated in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` — bump both.

## After every change to the runtime scripts: remind the user to reinstall

The status line runs the installed copy, so an edit in this repository has no effect until the user reinstalls. After any change to `statusline.py`, `history_bar.py`, `settings_helper.py` or `uninstall.sh`, end the reply with this reminder (the sandbox cannot write to `~/.claude/statusline/`, so the user runs it with the `!` prefix):

```
! bash <repo>/skills/prompt-history-bar/scripts/install.sh --lang zh --paste
```

- This user's installed `statusLine` uses `CLAUDE_HISTORY_PASTE=1` and `CLAUDE_HISTORY_LANG=zh`; keep both flags so a reinstall does not change the configuration. Re-running the installer is idempotent for `settings.json` and only refreshes the runtime files. Use `--force` only if the installer reports an existing `statusLine` it will not replace.
- Reinstalling with the same `statusLine` command needs no restart: Claude Code starts the status line command on each refresh, so the next refresh picks up the new files. A first install, which adds the `statusLine` key, still needs a new session or a settings reload.
- Changes that touch only `README.md`, `SKILL.md` or `tests/` do not need a reinstall.
- To check for drift: `cmp skills/prompt-history-bar/scripts/history_bar.py ~/.claude/statusline/prompt-history-bar/history_bar.py` (and likewise for the other runtime files).
