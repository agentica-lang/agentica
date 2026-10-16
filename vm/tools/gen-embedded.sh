#!/bin/sh
# Writes the assembly file that puts the front end and the std/ sources into the single binary (docs/vm/08-loader-and-cli.md).
# usage: gen-embedded.sh FRONT_END.agcb STDLIB_DIR MODULES_FILE > embedded.s
# The files are named relative to the directory the assembler runs in (the repository root). The index uses only
# differences between labels of one section, which the assembler turns into constants, so the binary needs no relocations
# for it. The layout is the one that vm/embedded.h describes.
# Each .incbin is preceded by a comment with the SHA-256 of the file: a compiler cache that keys on the text of this file
# (the object cache of zig cc, which the release builds with) sees a new key when the front end or a std/ source changes,
# which it cannot see through .incbin. The Makefile does not send this file through ccache, so it needs none of that.
# No globbing: the unquoted $names below is split into words only, so a "*" in MODULES reaches the check as a "*".
set -euf
front_end="${1:?usage: gen-embedded.sh FRONT_END.agcb STDLIB_DIR MODULES_FILE}"
stdlib="${2:?}"
modules="${3:?}"
for f in "$front_end" "$stdlib" "$modules"; do
  case "$f" in
    *[!A-Za-z0-9_./-]*|'') echo "gen-embedded: $f is not a plain path" >&2; exit 1 ;;
  esac
done
digest() { sha256sum "$1" | cut -d ' ' -f 1; }
names="$(sed '/^$/d' "$modules")"
for name in $names; do
  case "$name" in
    *[!A-Za-z0-9_./-]*|/*|*..*) echo "gen-embedded: $name is not a path inside stdlib/" >&2; exit 1 ;;
  esac
  [ -f "$stdlib/$name" ] || { echo "gen-embedded: $stdlib/$name is missing" >&2; exit 1; }
done
count=0
for name in $names; do count=$((count + 1)); done
printf '\t.section .rodata\n'
printf '\t.balign 16\n'
printf '\t.globl agc_embedded_data\n'
printf '\t.type agc_embedded_data, %%object\n'
printf 'agc_embedded_data:\n'
printf '/* sha256 %s %s */\n' "$(digest "$front_end")" "$front_end"
printf '.Lfront_end:\n\t.incbin "%s"\n.Lfront_end_end:\n' "$front_end"
k=0
for name in $names; do
  printf '.Lpath%d:\n\t.asciz "%s"\n' "$k" "$name"
  printf '/* sha256 %s %s/%s */\n' "$(digest "$stdlib/$name")" "$stdlib" "$name"
  printf '.Ltext%d:\n\t.incbin "%s/%s"\n.Ltext%d_end:\n' "$k" "$stdlib" "$name" "$k"
  k=$((k + 1))
done
printf '\t.size agc_embedded_data, . - agc_embedded_data\n\n'
printf '\t.balign 8\n'
printf '\t.globl agc_embedded_index\n'
printf '\t.type agc_embedded_index, %%object\n'
printf 'agc_embedded_index:\n'
printf '\t.quad .Lfront_end - agc_embedded_data\n\t.quad .Lfront_end_end - .Lfront_end\n\t.quad %d\n' "$count"
k=0
for name in $names; do
  printf '\t.quad .Lpath%d - agc_embedded_data\n\t.quad .Ltext%d - agc_embedded_data\n\t.quad .Ltext%d_end - .Ltext%d\n' "$k" "$k" "$k" "$k"
  k=$((k + 1))
done
printf '\t.size agc_embedded_index, . - agc_embedded_index\n\n'
printf '\t.section .note.GNU-stack,"",%%progbits\n'
