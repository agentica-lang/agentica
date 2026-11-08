#!/bin/sh
# Prints the compilation database of the VM (compile_commands.json, for clangd, clang-tidy and analyzers) for
# `make compile-commands` (mk/vm.mk). Each entry has the compiler and its flags as an "arguments" list, so no shell
# quoting is left to undo: -DAGC_VERSION="0.26.0" stays one argument with its quotes.
# Usage: compile-commands.sh DIRECTORY OBJ_DIR 'SOURCES' 'TEST_FLAGS' COMPILER FLAGS...
# A source under vm/tests/ also gets TEST_FLAGS, as its object rule does.
set -eu
dir=$1 obj=$2 sources=$3 test_flags=$4
shift 4

# A JSON string: the flags and paths hold no control characters, so only \ and " need escaping.
json() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }

list() {
  out=
  for a in "$@"; do out="$out$(json "$a"), "; done
  printf '%s' "$out"
}

args=$(list "$@")
# Word splitting is wanted: the sources and the test flags are lists of plain words.
tests=$(list $test_flags)
sep='['
for f in $sources; do
  o=$obj/${f#vm/}
  extra=
  case $f in vm/tests/*) extra=$tests ;; esac
  printf '%s\n  {"directory": %s, "file": %s, "arguments": [%s%s"-c", %s, "-o", %s]}' \
    "$sep" "$(json "$dir")" "$(json "$f")" "$args" "$extra" "$(json "$f")" "$(json "${o%.c}.o")"
  sep=,
done
printf '\n]\n'
