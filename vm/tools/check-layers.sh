#!/bin/sh
set -eu
export LC_ALL=C
fail=0
bad() { echo "vm layers: $*" >&2; fail=1; }
[ "$(uname -s)" = Linux ] || { bad "the link rules read ELF symbols with nm, so this check runs on Linux only"; exit 1; }
for tool in rg nm; do command -v "$tool" >/dev/null || { bad "$tool is not installed"; exit 1; }; done
obj="$(cd "${1:?usage: check-layers.sh OBJECT_DIR}" && pwd)"
cd "$(dirname "$0")/.."
core="value.c map.c equal.c text.c unicode_data.c json_value.c interp.c task.c loop.c input.c random.c loader.c builtins.c diag.c trace.c"
services="strings.c numbers.c json.c json_typed.c files.c stream.c process.c tcp.c http_fields.c http_client.c http_server.c testing.c"
adapters="tls_openssl.c http_pico.c http_body.c"
driver="main.c builtin_tables.c fuzz.c fuzz_main.c"
memory="agc_alloc agc_alloc_atomic agc_size_add agc_size_mul agc_out_of_memory"
found() { s=0; rg "$@" || s=$?; [ "$s" -le 1 ] || { bad "rg failed: $*"; return 1; }; [ "$s" -eq 0 ]; }
only() {
  globs=""
  for f in $2; do globs="$globs --glob !$f"; done
  if found -n --max-depth 1 "$1" --glob '*.c' --glob '*.h' $globs .; then bad "$1 outside $2"; fi
}
chain() {
  got="$(rg -o -I '^#include "[^"]+"' "$1")" || true
  [ "$got" = "#include \"$2\"" ] || bad "$1 must include only $2 of ours"
}

for f in *.c; do
  case " $core $services $adapters $driver " in *" $f "*) ;; *) bad "$f is in no layer" ;; esac
done
for f in $core $services $adapters $driver; do [ -f "$f" ] || bad "$f is listed but missing"; done

chain value.h trace.h
chain port.h value.h
chain core.h port.h
chain services.h port.h
if found -n '#include "(services|net|tls|http_parse|http_fields)\.h"' $core; then bad "a core file includes a service or adapter header"; fi
if found -n '#include "core\.h"' $services $adapters; then bad "a service or adapter includes core.h"; fi
if found -n '#include "(port|services|net|http_fields)\.h"' $adapters; then bad "an adapter includes the port or a service header"; fi
only '#include <gc\.h>' "value.c"
only '#include <openssl/' "tls_openssl.c"
only '#include <picohttpparser\.h>' "http_pico.c"
only '#include "yyjson\.h"' "json.c"
only '#include <uv\.h>' "loop.c stream.c process.c tcp.c http_client.c"
if found -n --max-depth 1 --pcre2 '^[A-Za-z_][\w \*]*\bagc_\w+\([^{]*\)\s*;\s*$' --glob '*.c' .; then bad "an agc_ prototype in a .c file"; fi
if found -n --max-depth 1 '^\s*extern\b.*\bagc_|^[A-Za-z_][\w \*]*\bagc_\w+\s*\[[^\]]*\]\s*;' --glob '*.c' .; then bad "an agc_ variable declared in a .c file"; fi

for f in $core $services $adapters; do
  [ -f "$obj/${f%.c}.o" ] || { bad "$obj/${f%.c}.o is missing: build the VM first"; exit 1; }
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
defined() { for f in $1; do nm -g --defined-only "$obj/${f%.c}.o"; done | awk '{print $NF}' | sort -u; }
used() { nm -u "$obj/${1%.c}.o" | awk '{print $NF}' | sort -u; }
{ defined "$services"; defined "$adapters"; } | sort -u > "$tmp/outside"
for f in $core; do
  used "$f" | comm -12 - "$tmp/outside" > "$tmp/hit"
  if [ -s "$tmp/hit" ]; then bad "core $f uses service or adapter symbols: $(tr '\n' ' ' < "$tmp/hit")"; fi
done
{ printf '%s\n' $memory; defined "$adapters"; } | sort -u > "$tmp/adapter-ok"
for f in $adapters; do
  used "$f" | { rg '^agc_' || true; } | comm -23 - "$tmp/adapter-ok" > "$tmp/hit"
  if [ -s "$tmp/hit" ]; then bad "adapter $f uses: $(tr '\n' ' ' < "$tmp/hit")"; fi
done
exit "$fail"
