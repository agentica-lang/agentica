#!/bin/sh
set -eu
src="$(cd "$(dirname "$0")/.." && pwd)"
obj="$(cd "${1:?usage: check-layers-test.sh OBJECT_DIR COMPILER [FLAGS...]}" && pwd)"
shift
cd "$src/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fresh() {
  rm -rf "$tmp/vm" "$tmp/obj"
  mkdir -p "$tmp/vm/tools" "$tmp/obj"
  cp "$src"/*.c "$src"/*.h "$tmp/vm/"
  cp "$src/tools/check-layers.sh" "$tmp/vm/tools/"
  cp "$obj"/*.o "$tmp/obj/"
}
build() { f="$1"; shift; "$@" -c "$tmp/vm/$f" -o "$tmp/obj/${f%.c}.o"; }
check() { sh "$tmp/vm/tools/check-layers.sh" "$tmp/obj" 2>&1; }
fails() {
  if out="$(check)"; then echo "check-layers.sh passed with $1" >&2; exit 1; fi
  printf '%s\n' "$out" | rg -q "$2" || { echo "check-layers.sh failed with $1, but not as expected:" >&2; printf '%s\n' "$out" >&2; exit 1; }
}

fresh
check >/dev/null || { echo "check-layers.sh fails on an unchanged copy" >&2; check >&2; exit 1; }

fresh
echo '#include "core.h"' >> "$tmp/vm/strings.c"
fails "a service that includes core.h" 'a service or adapter includes core.h'

fresh
printf '%s\n' 'typedef size_t plant_fn(uint32_t, char *);' 'plant_fn agc_utf8_encode;' \
  'size_t agc_plant(char *out) { return agc_utf8_encode(65, out); }' >> "$tmp/vm/text.c"
build text.c "$@"
fails "a core file that calls a service function" 'core text\.c uses service or adapter symbols: .*agc_utf8_encode'

fresh
echo 'agc_value agc_plant(void) { return agc_error_value("plant"); }' >> "$tmp/vm/http_body.c"
build http_body.c "$@"
fails "an adapter that calls a core function" 'adapter http_body\.c uses: .*agc_error_value'
echo "check-layers.sh: the planted violations fail as expected"
