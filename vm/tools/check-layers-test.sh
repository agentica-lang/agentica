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
plant() { fresh; printf '%s\n' "$2" >> "$tmp/vm/$1"; }
check() { sh "$tmp/vm/tools/check-layers.sh" "$tmp/obj" 2>&1; }
fails() {
  if out="$(check)"; then printf 'check-layers.sh passed with %s\n' "$1" >&2; exit 1; fi
  printf '%s\n' "$out" | rg -q "$2" || { printf 'check-layers.sh failed with %s, but not as expected:\n%s\n' "$1" "$out" >&2; exit 1; }
}

fresh
check >/dev/null || { printf 'check-layers.sh fails on an unchanged copy\n' >&2; check >&2; exit 1; }

plant extra.c ''
fails "a .c file in no layer" 'extra\.c is in no layer'
plant random.c '#include "services.h"'
fails "a core file that includes services.h" 'a core file includes a service'
plant strings.c '#include "core.h"'
fails "a service that includes core.h" 'a service or adapter includes core\.h'
plant http_body.c '#include "port.h"'
fails "an adapter that includes port.h" 'an adapter includes the port'
plant input.c '#include <uv.h>'
fails "uv.h in input.c" 'include of uv\\.h outside'
plant text.c '#include "list_impl.h"'
fails "list_impl.h in text.c" 'only list\.c, interp\.c and tests/list_test\.c may include list_impl\.h'
fresh
mkdir "$tmp/vm/tests"
printf '#include "../list_impl.h"\n' > "$tmp/vm/tests/list_test.c"
check >/dev/null || { printf 'check-layers.sh rejects list_impl.h in tests/list_test.c\n' >&2; check >&2; exit 1; }
printf '#include "../list_impl.h"\n' > "$tmp/vm/tests/map_test.c"
fails "list_impl.h in tests/map_test.c" 'only list\.c, interp\.c and tests/list_test\.c may include list_impl\.h'
plant text.c 'size_t agc_utf8_encode(uint32_t cp, char out[4]);'
fails "a prototype in a .c file" 'an agc_ prototype'
plant services.h '#include "core.h"'
fails "services.h that includes core.h" 'services\.h must include only: port\.h'
plant net.h '#include "core.h"'
fails "net.h that includes core.h" 'net\.h must include only: services\.h tls\.h'

plant text.c 'typedef size_t plant_fn(uint32_t, char *);'
printf '%s\n' 'plant_fn agc_utf8_encode;' 'size_t agc_plant(char *out) { return agc_utf8_encode(65, out); }' >> "$tmp/vm/text.c"
build text.c "$@"
fails "a core file that calls a service function" 'core text\.c uses service or adapter symbols: .*agc_utf8_encode'

plant http_body.c 'agc_value agc_plant(void) { return agc_error_value("plant"); }'
build http_body.c "$@"
fails "an adapter that calls a core function" 'adapter http_body\.c uses: .*agc_error_value'
printf 'check-layers.sh: the planted violations fail as expected\n'
