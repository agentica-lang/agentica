#!/bin/sh
set -eu
export LC_ALL=C
fail=0
bad() { printf 'vm layers: %s\n' "$*" >&2; fail=1; }
[ "$(uname -s)" = Linux ] || { bad "the link rules read ELF symbols with nm, so this check runs on Linux only"; exit 1; }
for tool in rg nm; do command -v "$tool" >/dev/null || { bad "$tool is not installed"; exit 1; }; done
obj="$(cd "${1:?usage: check-layers.sh OBJECT_DIR}" && pwd)"
cd "$(dirname "$0")/.."
core="value.c map.c list.c equal.c text.c unicode_data.c json_value.c interp.c task.c channel.c loop.c input.c output.c random.c loader.c builtins.c diag.c trace.c"
services="strings.c numbers.c json.c json_typed.c files.c tree.c stream.c duplex.c process.c tcp.c http_fields.c http_client.c http_server.c logger.c testing.c front_end.c"
adapters="tls_openssl.c http_pico.c http_body.c"
driver="main.c builtin_tables.c fuzz.c fuzz_main.c"
headers="value.h port.h core.h services.h net.h http_fields.h tls.h http_parse.h trace.h list_impl.h"
memory="agc_alloc agc_alloc_atomic agc_size_add agc_size_mul agc_out_of_memory"
inc='^\s*#\s*include\s*["<](\./)?'
found() { s=0; rg "$@" || s=$?; [ "$s" -le 1 ] || { bad "rg failed: $*"; return 1; }; [ "$s" -eq 0 ]; }
only() {
  globs=""
  for f in $2; do globs="$globs --glob !$f"; done
  if found -n --max-depth 1 "$inc$1" --glob '*.c' --glob '*.h' $globs .; then bad "include of $1 outside $2"; fi
}
chain() {
  f="$1"; shift; s=0
  got="$(rg -o -I -r '$1' '^\s*#\s*include\s*"([^"]+)"' "$f")" || s=$?
  [ "$s" -le 1 ] || bad "rg failed on $f"
  got="$(printf '%s ' $got)"
  [ "${got% }" = "$*" ] || bad "$f must include only: ${*:-nothing of ours}"
}

for f in *.c *.h; do
  case " $core $services $adapters $driver $headers " in *" $f "*) ;; *) bad "$f is in no layer" ;; esac
done
for f in $core $services $adapters $driver $headers; do [ -f "$f" ] || bad "$f is listed but missing"; done

chain value.h trace.h
chain list_impl.h value.h
chain port.h value.h
chain core.h port.h
chain services.h port.h
chain net.h services.h tls.h
chain http_fields.h services.h http_parse.h
chain tls.h
chain http_parse.h
chain trace.h
if found -n "$inc(services|net|tls|http_parse|http_fields)\.h" $core; then bad "a core file includes a service or adapter header"; fi
if found -n "${inc}core\.h" $services $adapters; then bad "a service or adapter includes core.h"; fi
if found -n "$inc(port|services|net|http_fields)\.h" $adapters; then bad "an adapter includes the port or a service header"; fi
only 'gc\.h' "value.c"
if found -n --max-depth 2 '^\s*#\s*include\s*"([^"]*/)?list_impl\.h"' --glob '*.c' --glob '*.h' --glob '!/list.c' --glob '!/interp.c' --glob '!/tests/list_test.c' .; then bad "only list.c, interp.c and tests/list_test.c may include list_impl.h"; fi
only 'openssl/' "tls_openssl.c"
only 'picohttpparser\.h' "http_pico.c"
only 'yyjson\.h' "json.c"
only 'uv\.h' "loop.c stream.c duplex.c process.c tcp.c http_client.c"
if found -n --max-depth 1 '^[A-Za-z_][\w \*]*\bagc_\w+\([^{]*\)\s*;\s*$' --glob '*.c' .; then bad "an agc_ prototype in a .c file"; fi
if found -n --max-depth 1 '^\s*extern\b.*\bagc_|^[A-Za-z_][\w \*]*\bagc_\w+\s*\[[^\]]*\]\s*;' --glob '*.c' .; then bad "an agc_ variable declared in a .c file"; fi

for f in $core $services $adapters; do
  [ -f "$obj/${f%.c}.o" ] || { bad "$obj/${f%.c}.o is missing: build the VM first"; exit 1; }
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
symbols() {
  f="$1"; shift
  nm "$@" "$obj/${f%.c}.o" > "$tmp/nm" || { bad "nm failed on ${f%.c}.o"; exit 1; }
  awk '{print $NF}' "$tmp/nm"
}
for f in $services; do symbols "$f" -g --defined-only; done > "$tmp/services"
for f in $adapters; do symbols "$f" -g --defined-only; done > "$tmp/adapters"
sort -u "$tmp/services" "$tmp/adapters" > "$tmp/outside"
for f in $core; do
  symbols "$f" -u > "$tmp/used"
  sort -u "$tmp/used" | comm -12 - "$tmp/outside" > "$tmp/hit"
  if [ -s "$tmp/hit" ]; then bad "core $f uses service or adapter symbols: $(tr '\n' ' ' < "$tmp/hit")"; fi
done
{ printf '%s\n' $memory; cat "$tmp/adapters"; } | sort -u > "$tmp/adapter-ok"
for f in $adapters; do
  symbols "$f" -u > "$tmp/used"
  sort -u "$tmp/used" | awk '/^agc_/' | comm -23 - "$tmp/adapter-ok" > "$tmp/hit"
  if [ -s "$tmp/hit" ]; then bad "adapter $f uses: $(tr '\n' ' ' < "$tmp/hit")"; fi
done
exit "$fail"
