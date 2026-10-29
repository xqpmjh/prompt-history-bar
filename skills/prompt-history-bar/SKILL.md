---
name: prompt-history-bar
description: Install, configure, or troubleshoot a Claude Code status line that shows recent prompts for the current project in a right-side column. Use when the user asks about prompt history in the status bar, a history sidebar, recent inputs shown in the status line, or wants to install, customize, or share this statusline setup.
---

# Prompt History Bar

Adds a right-side column to the Claude Code status line: the most recent prompts
entered in the current project, newest at the bottom, each with an age. The left
side keeps the usual project, model, effort, and context information.

Data comes from `<config>/history.jsonl`, which Claude Code writes locally. The
script makes no network requests and registers no hooks.

## Install

The plugin is installed under Claude Code's plugin directory, or as a personal
skill under `~/.claude/skills/prompt-history-bar/`. In both cases, run the
installer from the skill directory:

```bash
# Personal skill
bash ~/.claude/skills/prompt-history-bar/scripts/install.sh

# Plugin (the variable is expanded in skill content)
bash ${CLAUDE_PLUGIN_ROOT}/skills/prompt-history-bar/scripts/install.sh
```

The installer copies the runtime to `<config>/statusline/prompt-history-bar/`
and adds or replaces the `statusLine` key in `<config>/settings.json`.

**Ask the user before running it.** This edits their global settings. Show them
the exact command first, preferably with `--dry-run`:

```bash
bash .../install.sh --dry-run --lang en
```

Then run it after they agree.

Options:

| Option | Effect |
|---|---|
| `--lang en\|zh` | Age labels in English (default) or Chinese |
| `--paste` | Show the first line of pasted content instead of `[paste]` |
| `--force` | Replace a different existing `statusLine` command (backup kept) |
| `--dry-run` | Print the change; write nothing |
| `--uninstall` | Remove the `statusLine` entry |
| `--purge` | With `--uninstall`, also delete the runtime copy |

Without `--force`, the installer refuses to overwrite an existing `statusLine`
that points somewhere else. Every write is backed up as
`settings.json.bak.YYYYMMDD-HHMMSS` and validated before it replaces the file.

After installing, start a new Claude Code session or reload settings. The status
line is skipped until the workspace trust prompt is accepted.

## Configuration

Set these in the environment that launches Claude Code (for example
`~/.zshrc`):

| Variable | Meaning |
|---|---|
| `CLAUDE_HISTORY_LANG` | `en` (default) or `zh` |
| `CLAUDE_HISTORY_PASTE` | `1` to show the first line of pasted content |
| `CLAUDE_HISTORY_WIDTH` | Force a terminal width in cells |
| `CLAUDE_HISTORY_STYLE` | ANSI style for the history cells |
| `DEBUG` | `1` to log width decisions under the state directory |

The status line input JSON does not include terminal dimensions. Width comes
from tmux when `TMUX_PANE` is set, then from `COLUMNS` (which Claude Code sets
for status line commands), then `/dev/tty`, then the last successful value,
then 120. tmux gives the most reliable width; set `CLAUDE_HISTORY_WIDTH` when
running elsewhere.

## Troubleshooting

- **Nothing appears.** Accept the workspace trust prompt. Check
  `disableAllHooks: true` in settings (it disables the status line too), and
  check that managed settings are not overriding `statusLine`.
- **Only the left column appears.** The current project has no entries in
  `history.jsonl`, or the file is missing. Visiting a project creates entries.
- **The right column is misaligned.** Width detection failed. Set
  `CLAUDE_HISTORY_WIDTH`, or run Claude Code inside tmux.
- **Prompts from a parent directory appear.** That is intentional: if the exact
  directory has no entries, up to four parent directories are tried.
- **Pasted text shows `[paste]`.** Enable the preview with
  `CLAUDE_HISTORY_PASTE=1`. An input that is only a paste is not listed at all.
- **Uninstall.** Run
  `~/.claude/statusline/prompt-history-bar/uninstall.sh [--purge]`, or
  `install.sh --uninstall --purge` from the skill directory.

## Privacy

The script reads only local files:

- `<config>/history.jsonl` — the prompt history it displays.
- `<config>/paste-cache/<hash>.txt` — only when `CLAUDE_HISTORY_PASTE=1`.
- Git branch via `git -C <project> rev-parse` for the left column.

Nothing is uploaded. The history column displays prompt text on screen, so be
careful when screen-sharing or recording.

## How it works

`statusline.py` reads Claude Code's JSON from stdin, builds up to four left rows,
and calls `history_bar.render_statusline`. The history reader scans
`history.jsonl` backwards in 64 KiB blocks and stops as soon as it has enough
entries for the current project, so its cost does not grow with the file size.
It accepts both the logical project path and its realpath, tries parents up to
four levels, and ignores bash-mode inputs (`!...`), UI commands (`/effort`,
`/model`, ...), exit words, and inputs that are only paste or image
placeholders (`[Image #N]` is dropped from entries that also have text).

The right column is aligned to the terminal edge. With enough entries it uses
two columns; if the pane is too narrow it falls back to one, then to the left
column alone rather than overflowing.

## Development

Run the dependency-free checks with a throwaway HOME:

```bash
bash tests/run-tests.sh
```

The tests cover rendering, language labels, paste privacy, install, reinstall,
force replacement, uninstall, and syntax.