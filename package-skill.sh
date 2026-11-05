#!/usr/bin/env bash
# Build a distributable skill package for skill hubs (ModelScope Skills and any
# hub that follows the Anthropic Agent Skills layout).
#
# Output: dist/prompt-history-bar-<version>.zip, with SKILL.md at the zip root.
# The version is taken from .claude-plugin/plugin.json and injected into the
# SKILL.md front matter, which Claude Code does not require but the hubs do.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$repo_root/skills/prompt-history-bar"
manifest="$repo_root/.claude-plugin/plugin.json"
out_dir="$repo_root/dist"
max_bytes=$((5 * 1024 * 1024))

version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$manifest")"
[ -n "$version" ] || { echo "package-skill: no version in $manifest" >&2; exit 1; }

stage="$(mktemp -d "${TMPDIR:-/tmp}/prompt-history-bar.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# Copy the package payload, leaving out build artefacts.
mkdir -p "$stage/scripts"
cp "$skill_dir/SKILL.md" "$stage/SKILL.md"
for f in "$skill_dir"/scripts/*; do
  case "$(basename "$f")" in
    __pycache__) continue ;;
  esac
  cp "$f" "$stage/scripts/"
done

# Inject (or replace) the version line in the front matter.
python3 - "$stage/SKILL.md" "$version" <<'PY'
import re, sys

path, version = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
if not text.startswith("---\n"):
    sys.exit("SKILL.md has no YAML front matter")
end = text.index("\n---", 4) + 1
head, body = text[:end], text[end:]
head = re.sub(r'^version:.*\n', '', head, flags=re.M)
head = head.replace("\ndescription:", f'\nversion: "{version}"\ndescription:', 1)
open(path, "w", encoding="utf-8").write(head + body)
PY

mkdir -p "$out_dir"
zip_path="$out_dir/prompt-history-bar-$version.zip"
rm -f "$zip_path"
(cd "$stage" && zip -qrX "$zip_path" .)

# Sanity checks the hubs enforce.
count="$(unzip -Z1 "$zip_path" | grep -cx 'SKILL.md' || true)"
[ "$count" = "1" ] || { echo "package-skill: expected one root SKILL.md, found $count" >&2; exit 1; }
bytes="$(wc -c < "$zip_path" | tr -d ' ')"
[ "$bytes" -le "$max_bytes" ] || { echo "package-skill: package is $bytes bytes, over the 5 MiB limit" >&2; exit 1; }

echo "built $zip_path (version $version, $bytes bytes)"
unzip -Z1 "$zip_path" | sed 's/^/  /'
