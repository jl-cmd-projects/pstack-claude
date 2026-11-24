#!/usr/bin/env bash
set -euo pipefail

pin_sha=""
remote_override=""
bun_bin="${BUN_BIN:-bun}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pin)
      pin_sha="${2:?missing sha for --pin}"
      shift 2
      ;;
    --remote)
      remote_override="${2:?missing url for --remote}"
      shift 2
      ;;
    *)
      echo "usage: sync-cursor-upstream.sh [--pin <sha>] [--remote <url>]" >&2
      exit 2
      ;;
  esac
done

remote="${remote_override:-$(jq -r '.remote' tools/upstream.json)}"
upstream_path="$(jq -r '.components.pstack.upstreamPath' tools/upstream.json)"
pinned_sha="$(jq -r '.components.pstack.sha' tools/upstream.json)"

if [ -n "$pin_sha" ]; then
  target_sha="$pin_sha"
else
  probe_dir="$(mktemp -d)"
  trap 'rm -rf "$probe_dir"' EXIT
  git clone --quiet --filter=blob:none --no-checkout "$remote" "$probe_dir/repo"
  target_sha="$(git -C "$probe_dir/repo" log -1 --format=%H HEAD -- "$upstream_path")"
  if [ -z "$target_sha" ]; then
    echo "could not resolve latest commit for ${upstream_path} in ${remote}" >&2
    exit 1
  fi
  if [ "$target_sha" = "$pinned_sha" ]; then
    echo "cursor/plugins ${upstream_path} already at ${pinned_sha}"
    exit 0
  fi
  if ! git -C "$probe_dir/repo" merge-base --is-ancestor "$pinned_sha" "$target_sha"; then
    echo "cursor/plugins ${target_sha} is not a descendant of pinned ${pinned_sha}; skipping"
    exit 0
  fi
fi

if [ "$target_sha" = "$pinned_sha" ]; then
  echo "cursor/plugins ${upstream_path} already at ${pinned_sha}"
  exit 0
fi

"$bun_bin" tools/sync.mjs pstack "$target_sha"

if grep -rn '^<<<<<<< ' plugins/pstack > /dev/null 2>&1; then
  echo "unresolved merge conflict markers in plugins/pstack after syncing ${target_sha}" >&2
  grep -rn '^<<<<<<< ' plugins/pstack >&2 || true
  exit 1
fi

TARGET_SHA="$target_sha" python3 - <<'PYEOF'
import os
import re
from pathlib import Path

ref_path = Path("docs/reference.md")
skills_root = Path("plugins/pstack/skills")
short_sha = os.environ["TARGET_SHA"][:7]
if ref_path.is_file() and skills_root.is_dir():
    text = ref_path.read_text(encoding="utf-8")
    all_skills = sorted(skill_md.parent.name for skill_md in skills_root.glob("*/SKILL.md"))
    principle_count = sum(1 for name in all_skills if name.startswith("principle-"))
    public_count = len(all_skills) - principle_count
    total_count = len(all_skills)
    existing = set(re.findall(r"^\|\s*`/([a-z0-9-]+)`\s*\|", text, re.M))
    missing_rows = []
    for name in all_skills:
        if name.startswith("principle-") or name in existing:
            continue
        raw = (skills_root / name / "SKILL.md").read_text(encoding="utf-8")
        match = re.search(r"^description:\s*(.+)$", raw, re.M)
        desc = match.group(1).strip().strip('"').strip("'") if match else f"run /{name}"
        desc = re.sub(r"\s*Use for\b.*$", "", desc).strip().rstrip(".")
        if desc:
            desc = desc[0].lower() + desc[1:]
        missing_rows.append(f"| `/{name}` | {desc} |")
    if missing_rows:
        lines = text.splitlines()
        last_row = max(
            idx for idx, line in enumerate(lines)
            if re.match(r"^\|\s*`/[a-z0-9-]+`\s*\|", line)
        )
        text = "\n".join(lines[: last_row + 1] + missing_rows + lines[last_row + 1 :]) + "\n"
    text = re.sub(
        r"\b\d+ skill directories: \d+ public skills and \d+ `principle-\*` references",
        f"{total_count} skill directories: {public_count} public skills and {principle_count} `principle-*` references",
        text,
    )
    text = re.sub(
        r"synced against upstream `[0-9a-f]+`",
        f"synced against upstream `{short_sha}`",
        text,
    )
    ref_path.write_text(text, encoding="utf-8", newline="\n")
PYEOF

"$bun_bin" tools/generate.mjs
"$bun_bin" tools/generate.mjs --check
echo "synced cursor/plugins ${upstream_path}: ${pinned_sha:0:7} -> ${target_sha:0:7}"
