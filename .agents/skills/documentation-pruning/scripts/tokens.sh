#!/usr/bin/env bash
# Token counts (tiktoken o200k_base) for Markdown/text files, shown as a tree.
# Part of the documentation-pruning skill; run from the repository root.
# Usage: .agents/skills/documentation-pruning/scripts/tokens.sh [PATH...]
#   (default: docs .agents/skills)
# Requires: uv on PATH (fetches tiktoken on first run; needs network once).
set -euo pipefail
if ! command -v uv >/dev/null 2>&1; then
  echo "tokens.sh needs 'uv' on PATH (it runs tiktoken through 'uv run')." >&2
  exit 1
fi
if [ "$#" -eq 0 ]; then set -- docs .agents/skills; fi
exec uv run --no-project -q --with tiktoken python - "$@" <<'PY'
import os, sys, tiktoken
enc = tiktoken.get_encoding("o200k_base")
EXTS = {".md", ".txt"}

def count(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    return len(enc.encode(text)), len(text.encode())

def walk(path, prefix, lines):
    """Append tree lines for path; return (tokens, bytes, files)."""
    if os.path.isfile(path):
        t, b = count(path)
        return t, b, 1
    entries = sorted(e for e in os.listdir(path) if not e.startswith(".git"))
    children = []
    total_t = total_b = total_f = 0
    for name in entries:
        full = os.path.join(path, name)
        if os.path.isfile(full) and os.path.splitext(name)[1] not in EXTS:
            continue
        children.append((name, full))
    for i, (name, full) in enumerate(children):
        last = i == len(children) - 1
        branch = "└── " if last else "├── "
        ext = "    " if last else "│   "
        sub = []
        t, b, f = walk(full, prefix + ext, sub)
        if f == 0:
            continue
        label = name + ("/" if os.path.isdir(full) else "")
        if os.path.isfile(full):
            lines.append(f"{prefix}{branch}{label}  {t} tok  {b} B")
        else:
            lines.append(f"{prefix}{branch}{label}  {t} tok  {f} files")
            lines.extend(sub)
        total_t += t; total_b += b; total_f += f
    return total_t, total_b, total_f

grand_t = grand_b = grand_f = 0
for arg in sys.argv[1:]:
    lines = []
    t, b, f = walk(arg, "", lines)
    print(f"{arg}/  {t} tok  {b} B  {f} files")
    print("\n".join(lines))
    print()
    grand_t += t; grand_b += b; grand_f += f
print(f"TOTAL  {grand_t} tok  {grand_b} B  {grand_f} files")
PY
