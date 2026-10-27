# Submission notes

Use this as the source text for the Claude plugin directory submission form.
Replace the repository URL after the public repo exists.

## Where to submit

There are two different things:

- `anthropics/claude-plugins-official` is the curated GitHub marketplace. New
  entries are added by Anthropic. Its README points external submissions to the
  directory form, and the docs say official-marketplace listings go through a
  partner contact. Do not open a PR: non-member PRs are closed automatically.
- The **Claude plugin directory** is the public submission path. It requires a
  paid claude.ai plan (Pro, Max, Team, or Enterprise) and a public GitHub repo.
  Automated validation and a security scan run on each version, plus human
  review for a new listing.

Submit through the directory. An official-marketplace listing is a separate
partner conversation and is not something this form guarantees.

## Without a paid plan

The directory requires a paid claude.ai plan. The repository also ships a
self-hosted marketplace (`.claude-plugin/marketplace.json`), so no listing is
needed:

```text
/plugin install prompt-history-bar --marketplace xqpmjh/prompt-history-bar
```

Verified 2026-10-28 with a throwaway config: `claude plugin marketplace add`,
`claude plugin install`, and the plugin inventory (1 skill) all succeed from a
local clone. `claude plugin validate . --strict` passes.

## Steps

1. Create a public GitHub repo containing this plugin (repo root = this folder).
2. Connect the GitHub account on claude.ai with push access. The repo may stay
   private during validation and review, but must be public before the listing
   goes live.
3. Run `claude plugin validate ./prompt-history-bar --strict` and fix anything
   it reports.
4. Work through the pre-submission checklist:
   https://claude.com/docs/plugins/pre-submission-checklist
5. Open https://claude.ai/directory/manage, choose **Submit new → Plugin
   bundle**, validate, and submit for review.
6. Record the commit SHA you submitted. The directory tracks a branch/tag and
   rescans each version; it may pin the SHA in its listing.

Requirements: a paid claude.ai plan (Pro, Max, Team, or Enterprise), a public
repo, a README, and a LICENSE file. Review combines automated validation, a
security scan per version, and human review for a new listing.

## Basic fields

- **Name / slug:** `prompt-history-bar`
- **Display name:** Prompt History Bar
- **Category:** productivity
- **License:** MIT
- **Repository:** https://github.com/xqpmjh/prompt-history-bar
- **Homepage:** https://github.com/xqpmjh/prompt-history-bar
- **Author:** Hao Jin (https://github.com/xqpmjh)

## Short description

Show recent prompts for the current project in a right-side column of the
Claude Code status line. Reads local prompt history only; no network, hooks, or
telemetry.

## Long description

Prompt History Bar adds a right-side column to the Claude Code status line with
the most recent prompts entered in the current project, newest at the bottom,
each with an age. The left side keeps the usual project/branch, model, effort,
and context information.

It is project-scoped: each repository shows its own recent inputs. If the exact
directory has no entries, it tries parent directories up to four levels. Bash
commands (`!...`), UI-setting commands (`/effort`, `/model`, ...), and exit
words are filtered out.

The status line reads `<config>/history.jsonl` locally. Paste previews are
opt-in and read `<config>/paste-cache`; by default a paste is shown as
`[paste]`. There are no network calls, hooks, telemetry, MCP servers, or
background processes. Installation writes one `statusLine` key to
`settings.json`, after backing the file up; uninstall removes only that key.

## Security and privacy answers

- **Network access:** none.
- **Hooks:** none.
- **Telemetry / analytics:** none.
- **Data read at runtime:** `<config>/history.jsonl` (the prompts displayed),
  optional `<config>/paste-cache` when `CLAUDE_HISTORY_PASTE=1`, and the git
  branch via `git -C <project> rev-parse`.
- **Data written:** `<config>/statusline/prompt-history-bar/` (the runtime copy)
  and the `statusLine` entry in `<config>/settings.json`, only when the user runs
  the installer; a timestamped backup of settings is kept.
- **Data sent off the machine:** none.
- **Surprising behavior:** none beyond installing the status line; the skill
  asks the user to confirm before editing settings.

## Demo

- Screenshot/GIF: capture a terminal showing the right-side column after a few
  prompts in one project.
- Tested: 2026-10-27 on macOS with the current Claude Code release; tmux and
  non-tmux paths checked.

## Reviewer notes

- `settings_helper.py` performs a minimal text replacement so an existing
  `settings.json` keeps its formatting; the result is parsed and compared
  against the original before writing.
- `install.sh --dry-run` shows the exact command without touching anything.
- `tests/run-tests.sh` uses a throwaway HOME and covers rendering, privacy,
  install, reinstall, force replacement, and uninstall.