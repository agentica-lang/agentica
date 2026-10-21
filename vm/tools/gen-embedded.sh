#!/bin/sh
# Writes the assembly file that puts the front end, the std/ sources and two programs of `agentica test` into the single
# binary (docs/vm/08-loader-and-cli.md).
# usage: gen-embedded.sh FRONT_END.agcb STDLIB_DIR MODULES_FILE [RUNNER.agcb STEPS.agcb [CORE_FILE COMPILER_DIR]] >
#        embedded.s
# The runner and the default step program are optional: without them (the first binary of the bootstrap, which cannot
# compile them yet) their length is 0 and `agentica test` compiles them as it did before.
# The core file lists files of COMPILER_DIR (the pure core of the front end, which std/analysis compiles into the user's
# program): each one is carried as the std/ source internal/compiler/<name>, so a program reads it with Std.source.
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
runner="${4:-}"
steps="${5:-}"
core="${6:-}"
compiler="${7:-}"
for f in "$front_end" "$stdlib" "$modules" "$runner" "$steps" "$core" "$compiler"; do
  case "$f" in
    *[!A-Za-z0-9_./-]*) echo "gen-embedded: $f is not a plain path" >&2; exit 1 ;;
  esac
done
[ -z "$runner" ] && [ -n "$steps" ] && { echo "gen-embedded: a step program needs a runner" >&2; exit 1; }
[ -n "$core" ] && [ -z "$compiler" ] && { echo "gen-embedded: a core file needs the compiler folder" >&2; exit 1; }
digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}
names="$(sed '/^$/d' "$modules")"
for name in $names; do
  case "$name" in
    *[!A-Za-z0-9_./-]*|/*|*..*) echo "gen-embedded: $name is not a path inside stdlib/" >&2; exit 1 ;;
  esac
  [ -f "$stdlib/$name" ] || { echo "gen-embedded: $stdlib/$name is missing" >&2; exit 1; }
done
core_names=
if [ -n "$core" ]; then
  core_names="$(sed '/^$/d' "$core")"
fi
for name in $core_names; do
  case "$name" in
    *[!A-Za-z0-9_./-]*|/*|*..*) echo "gen-embedded: $name is not a path inside compiler/" >&2; exit 1 ;;
  esac
  [ -f "$compiler/$name" ] || { echo "gen-embedded: $compiler/$name is missing" >&2; exit 1; }
done
count=0
for name in $names $core_names; do count=$((count + 1)); done
format="${AGENTICA_OBJECT_FORMAT:-$(uname -s)}"
prefix=
case "$format" in
  Linux|elf) format=elf; printf '\t.section .rodata\n' ;;
  Darwin|macho) format=macho; prefix=_; printf '\t.section __TEXT,__const\n' ;;
  MINGW*|MSYS*|coff) format=coff; printf '\t.section .rdata,"dr"\n' ;;
  *) echo "gen-embedded: unsupported object format: $format" >&2; exit 1 ;;
esac
printf '\t.balign 16\n'
printf '\t.globl %sagc_embedded_data\n' "$prefix"
if [ "$format" = elf ]; then printf '\t.type agc_embedded_data, %%object\n'; fi
printf '%sagc_embedded_data:\n' "$prefix"
printf '/* sha256 %s %s */\n' "$(digest "$front_end")" "$front_end"
printf '.Lfront_end:\n\t.incbin "%s"\n.Lfront_end_end:\n' "$front_end"
# An absent program is an empty range between two labels.
embed() {
  printf '.L%s:\n' "$1"
  if [ -n "$2" ]; then
    printf '/* sha256 %s %s */\n' "$(digest "$2")" "$2"
    printf '\t.incbin "%s"\n' "$2"
  fi
  printf '.L%s_end:\n' "$1"
}
embed runner "$runner"
embed steps "$steps"
k=0
for name in $names; do
  printf '.Lpath%d:\n\t.asciz "%s"\n' "$k" "$name"
  printf '/* sha256 %s %s/%s */\n' "$(digest "$stdlib/$name")" "$stdlib" "$name"
  printf '.Ltext%d:\n\t.incbin "%s/%s"\n.Ltext%d_end:\n' "$k" "$stdlib" "$name" "$k"
  k=$((k + 1))
done
for name in $core_names; do
  printf '.Lpath%d:\n\t.asciz "internal/compiler/%s"\n' "$k" "$name"
  printf '/* sha256 %s %s/%s */\n' "$(digest "$compiler/$name")" "$compiler" "$name"
  printf '.Ltext%d:\n\t.incbin "%s/%s"\n.Ltext%d_end:\n' "$k" "$compiler" "$name" "$k"
  k=$((k + 1))
done
if [ "$format" = elf ]; then printf '\t.size agc_embedded_data, . - agc_embedded_data\n\n'; fi
printf '\t.balign 8\n'
printf '\t.globl %sagc_embedded_index\n' "$prefix"
if [ "$format" = elf ]; then printf '\t.type agc_embedded_index, %%object\n'; fi
printf '%sagc_embedded_index:\n' "$prefix"
printf '\t.quad .Lfront_end - %sagc_embedded_data\n\t.quad .Lfront_end_end - .Lfront_end\n' "$prefix"
printf '\t.quad .Lrunner - %sagc_embedded_data\n\t.quad .Lrunner_end - .Lrunner\n' "$prefix"
printf '\t.quad .Lsteps - %sagc_embedded_data\n\t.quad .Lsteps_end - .Lsteps\n' "$prefix"
printf '\t.quad %d\n' "$count"
k=0
for name in $names $core_names; do
  printf '\t.quad .Lpath%d - %sagc_embedded_data\n\t.quad .Ltext%d - %sagc_embedded_data\n\t.quad .Ltext%d_end - .Ltext%d\n' "$k" "$prefix" "$k" "$prefix" "$k" "$k"
  k=$((k + 1))
done
if [ "$format" = elf ]; then printf '\t.size agc_embedded_index, . - agc_embedded_index\n\n'; fi
if [ "$format" = elf ]; then printf '\t.section .note.GNU-stack,"",%%progbits\n'; fi
