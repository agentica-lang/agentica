## 10. Dependencies and platforms

The VM runs on Linux, macOS and Windows, always in the "C" locale. Windows
specifics: binary-mode stdio, UTF-8 arguments from `wmain`,
`BCryptGenRandom`, `GetSystemTimePreciseAsFileTime`,
`QueryPerformanceCounter`; console rendering is outside the contract.
Paths over 260 characters (`MAX_PATH`) fail with `_wopen` today; 7h, which
opens files, picks `\\?\` prefixes or a `longPathAware` manifest.

| Dependency | When | Choice |
|---|---|---|
| C compiler | 7e | C11, gcc or clang. Windows: MSYS2 UCRT64 gcc. No MSVC: it lacks `__builtin_*_overflow`, and one compiler family keeps one Makefile. |
| libc | 7e | Dynamic (static glibc breaks NSS; macOS forbids static libc). |
| Boehm GC | 7e | Vendored: git submodule `vm/third_party/bdwgc`, pinned to tag v8.2.12. `make vm` compiles its single-file amalgamation (`extra/gc.c`) and links it statically (with `-lpthread` on Linux and macOS). No system package. |
| yyjson | 7 (JSON) | Vendored: git submodule `vm/third_party/yyjson` (MIT, its `LICENSE` stays in the submodule), pinned to tag 0.13.0. Only the reader: `make vm` compiles `src/yyjson.c` into its own object (`$(VM_BUILD)/yyjson.o`, with the sanitizers in a `SANITIZE=1` build but without `-Werror`) with the writer, incremental reader, file API, JSON Pointer/Patch, non-standard extensions and its own float conversion disabled. Its reader does not recurse and is fuzzed on OSS-Fuzz. It allocates with `malloc` and holds no GC pointers; the document is freed right after the copy into GC nodes (2.6). Under `AGC_NO_GC` it allocates through `agc_alloc_atomic` instead (freeing is a no-op), so the fuzzer's per-mutant limit counts it. The encoder is our own (2.4), since yyjson's writer formats floats and escapes differently. |
| libuv | 7h | Vendored the same way: git submodule `vm/third_party/libuv` from `https://github.com/libuv/libuv` (MIT, with BSD-2-Clause and ISC parts in its `LICENSE-extra`; both files stay in the submodule and ship with releases), pinned to tag v1.53.0. `make vm` compiles its Linux sources (the list in its `CMakeLists.txt`) per build mode into `$(VM_BUILD)/uv/` with its own defines (`-std=gnu11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64`), the mode's flags (the sanitizers in `SANITIZE=1`, no `-Werror`), and links `$(VM_BUILD)/libuv.a` statically with `-ldl -lrt`. Linux only for now; macOS and Windows builds leave it out and have no file builtins. No system package. |
| picohttpparser | 7h (HTTP) | Vendored: git submodule `vm/third_party/picohttpparser` from `https://github.com/h2o/picohttpparser` (dual MIT or Perl license; we take MIT; the notice is in `picohttpparser.h`, and releases ship it extracted to a license file), pinned to tag v1.4 (commit `516cdd3e00b3`). It parses and validates the start line and headers (`phr_parse_request`, `phr_parse_response`), behind our adapter (10.6); `phr_decode_chunked` is not used, since it knows no limits. `make vm` compiles `picohttpparser.c` per build mode into `$(VM_BUILD)/picohttpparser.o`, like yyjson, at the baseline (no `-msse4.2`; its SSE4.2 path is a SIMD candidate, `docs/future/19-simd.md` §19). Everything else in HTTP is our own C. |
| OpenSSL 3.5 LTS | 7h (TLS) | Vendored for the release: git submodule `vm/third_party/openssl` from `https://github.com/openssl/openssl` (Apache-2.0; its `LICENSE.txt` stays in the submodule and ships with releases), shallow, pinned to tag `openssl-3.5.9`. `make vm AGENTICA_OPENSSL=vendored` builds `libssl.a` and `libcrypto.a` per build mode into `$(VM_BUILD)/openssl/` (10.0) and links them statically; the release builds this way, and OpenSSL's `Configure` needs Perl 5. The default `AGENTICA_OPENSSL=system` (user decision of 2026-10-13) links the system OpenSSL 3.0 or newer dynamically, found with `pkg-config` (Debian: `libssl-dev`), so a fresh checkout does not spend minutes building OpenSSL. Only `vm/tls_openssl.c` includes OpenSSL headers (`docs/vm/10-io-tls-processes-http.md` 10.3). |

License rule: vendored or statically linked third-party code must be MIT,
BSD, ISC, zlib, Apache-2.0 or similarly permissive (no copyleft). Its
license file stays with it (in the submodule) and ships with releases.
Where there is no license file, releases ship the notice extracted to one:
bdwgc's from its `README.QUICK`, like picohttpparser's from its header.
The notices that ship with the VM also include the Unicode License v3
notice for `vm/unicode_data.c`, which is generated from Unicode data.
OpenSSL 3 is Apache-2.0, which adds an attribution duty: releases ship its
`LICENSE.txt` (and a `NOTICE` file if a later version adds one; 3.5 has
none) in `licenses/openssl/`, since the VM links it statically (10.0).
Agentica itself is `Apache-2.0 WITH LLVM-exception`,
and releases ship its `LICENSE` and `NOTICE` alongside the third-party
licenses.

### 10.0 Building and linking OpenSSL

The `AGENTICA_OPENSSL` make variable picks the OpenSSL build (user decision of
2026-10-13, replacing the static-everywhere decision of 2026-10-12):

- `system` (the default) links the system OpenSSL dynamically with the
  flags from `pkg-config --cflags --libs openssl`. The stamp
  `$(VM_BUILD)/openssl-system`, the first prerequisite of every VM binary
  and of `vm-lint` and an order-only prerequisite of every VM object, so
  it runs before any `vm/*.c` compile (under `-j` the third-party
  libraries may start beside it); it stops with a clear message when
  `pkg-config` or the package is missing, or when its version is older
  than `OSSL_MIN` (3.0.0: the adapter uses 3.0 APIs such as
  `SSL_CTX_load_verify_file`, `ERR_SYSTEM_ERROR` and
  `OPENSSL_VERSION_STRING`); `vm/tls_openssl.c` also stops with `#error`
  on an older OpenSSL or on LibreSSL, whose version number passes the
  `pkg-config` check. The stamp holds the version and flags, so a new
  system OpenSSL relinks. The rest of this section does not apply to it:
  no Perl, no cache.
- `vendored` builds the pinned submodule and links it statically into
  `dist/agentica-vm`. The release sets it, so the shipped VM needs only
  glibc's own libraries (libc, libm, libpthread, libdl; `readelf -d` shows
  no `libssl` or `libcrypto`) and runs on any glibc 2.28 system. Every
  CI job, the sanitizer one included, uses `system`; the `test` job links
  one vendored release-mode binary from a cached OpenSSL and, on a cache
  hit, runs the TLS tests on it, so this path stays tested (11).

The mode is not remembered: pass `AGENTICA_OPENSSL=vendored` to every make
command, or export it, since `make test` and the Racket tests run `make
-s vm` themselves. `build/vm/flags` records the mode, so switching it
relinks the VM.
`agentica-vm --version` prints the version of the OpenSSL that runs.
The rest of this section describes the vendored build.

- Linux only for now, like libuv. On macOS and Windows (paused) the
  Makefile leaves OpenSSL out and `vm/tls_openssl.c` has stubs.
- Build: the rule for `$(VM_BUILD)/openssl/libcrypto.a` runs OpenSSL's
  `Configure` out of tree in `$(VM_BUILD)/openssl/` with the mode's
  compiler (`VM_CC`: `cc`, `clang` for `SANITIZE=1`, `zig cc` in the
  release), then `make build_libs` there with `-j $(JOBS)` and the same
  `CC` (`OSSL_CONFIGURE` and `OSSL_SUBMAKE`). Both run under `env -u` for
  `MAKEFLAGS`, `MFLAGS`, `MAKELEVEL`, `MAKEOVERRIDES`, `CC`, `CFLAGS`,
  `CPPFLAGS`, `CXXFLAGS`, `LDFLAGS` and `LDLIBS`, so nothing from the
  parent make or its command line leaks in; the flags come only from
  Configure's own and `OSSL_CFLAGS`. The sub-make is a plain `make`, not
  `$(MAKE)`, so `make -n` does not run it. Its output goes to `configure.log`
  and `build.log` in that directory; a failure prints their tail. It
  needs Perl 5 with its core modules for `Configure` (on Debian the
  `perl` package; `perl-base` alone lacks `IPC::Cmd`). The rule stops with
  a clear message when they are missing; CI then installs `perl`.
- Options (`OSSL_OPTS` in the Makefile): `no-shared no-tests no-docs
  no-apps`, no loadable code (`no-module no-dso no-engine`), no legacy
  provider, no automatic `openssl.cnf` loading (`no-autoload-config`),
  and no parts TLS does not use (`no-async no-comp no-ssl3 no-dtls no-srp
  no-quic no-ui-console no-cmp no-ts no-ct no-ocsp no-http`), plus
  `no-deprecated`, so only the 3.x API is visible. Assembly stays on (it
  builds with gcc, clang and `zig cc`). The static libraries are PIC
  (OpenSSL adds `-fPIC`), so the PIE link works.
- Flags per mode (`OSSL_CFLAGS`): the release mode adds
  `-fstack-protector-strong -D_FORTIFY_SOURCE=2`; the GC-stress mode adds
  `-g`; the sanitizer mode builds with clang and `-g
  -fno-omit-frame-pointer` but without `-fsanitize`. A non-instrumented
  OpenSSL is enough there: the ASan run is for our own C code; OpenSSL is
  fuzzed with sanitizers upstream (OSS-Fuzz); ASan still replaces
  `malloc` and checks OpenSSL's `memcpy` and friends through its
  interceptors, so an overflow of a buffer our code hands to OpenSSL is
  still caught there; and an instrumented OpenSSL would make its build
  and every TLS test in the sanitizer job much slower.
- Stamp: `$(VM_BUILD)/openssl-flags` holds the Configure and sub-make
  command lines (without the checkout path and `-j`), so they carry the
  compiler, the options and the mode's flags, then the first line of
  `$(VM_CC) --version`, the submodule's `VERSION.dat` and its commit. A
  change to the recipe changes the key, which rebuilds locally and misses
  the CI cache. It is rewritten only when that text changes,
  and the libraries depend only on it (not on the OpenSSL source files'
  times), so toggling `TRACE` or touching sources never rebuilds OpenSSL,
  and a CI cache restore is up to date. libgc, yyjson, picohttpparser and
  libuv follow the same model with `$(VM_BUILD)/third-party-flags` and
  `build/vm/gc-flags` (`make -s vm-third-party-key`, 11). `make vm-openssl-key` prints the
  same text; CI hashes it into the cache key (11) and caches only
  `include/`, `libssl.a`, `libcrypto.a` and the stamp, which is all the
  VM build reads. `make vm-openssl`
  builds only the libraries. After editing OpenSSL
  sources by hand, remove `$(VM_BUILD)/openssl` to rebuild.
- Headers: `vm/*.c` see `-I $(VM_BUILD)/openssl/include -I
  vm/third_party/openssl/include` (the first holds the generated
  `opensslv.h` and `configuration.h`); only `vm/tls_openssl.c` includes
  them. `make vm-lint` builds the mode's OpenSSL first for those headers.
- Initialization: `OPENSSL_init_ssl(OPENSSL_INIT_NO_LOAD_CONFIG |
  OPENSSL_INIT_NO_ATEXIT, NULL)`, because the built-in `OPENSSLDIR`
  points at the build machine and the VM may end with `_exit` while a
  pool thread still runs. Contexts set TLS 1.2 and security level 2 as
  minimums themselves. The CA store is found as in 10.3.
- `--version` prints the OpenSSL version (`OpenSSL_version(
  OPENSSL_VERSION_STRING)`, for example `OpenSSL 3.5.9`).
- Bumping: check out the new 3.5.x tag inside `vm/third_party/openssl`
  (`git fetch --depth 1 origin tag openssl-3.5.N`), `git add
  vm/third_party/openssl`, rebuild (the changed `VERSION.dat` changes the
  stamp and the CI keys), and rerun the TLS, sanitizer and diff tests.
  Moving to the next LTS line is a reviewed change of its own.
- Rejected: loading OpenSSL with `dlopen` only when a program uses TLS
  (more complex, and the static build costs only binary size: about 6 MB
  more for `dist/agentica-vm`).

### 10.1 Event loop: libuv, not libevent

| Need (current API) | libevent | libuv |
|---|---|---|
| TCP, timers (`TCP.*`, `Task.sleep`, timeouts) | Yes | Yes |
| Spawn with stdio pipes, kill, exit status (`Process.*`) | No; per-platform code by hand | `uv_spawn`, `uv_process_kill` |
| Child pipes with timeouts on Windows | No; Windows backends watch sockets only | `uv_pipe_t` (IOCP) |
| Stdin read in one task while others run, on a Windows console or pipe | No | `uv_tty_t` / `uv_pipe_t` |
| File I/O with timeouts and UTF-8 paths on Windows (`File.*`, `Dir.*`) | No | `uv_fs_*` on a thread pool |
| DNS | `evdns` | `uv_getaddrinfo` |
| TLS | `bufferevent_openssl` | None; OpenSSL with memory BIOs |

With libevent, Windows would need a hand-written process layer, helper
threads relaying pipe and console reads into the loop, and a separate file
path: most of what libuv is, and the hardest platform code to get right. So
the gap blocks `Process`, stdin and `File` on Windows, and the choice is
libuv. Its cost is about 200 lines to drive OpenSSL through memory BIOs.

libuv also stays for multicore (10.2.3); we do not replace it with raw
epoll or io_uring. libuv works with one loop per thread, which is what
one loop per scheduler needs. It gives the thread pool for files (epoll
cannot poll regular files), process spawn, signals and DNS, which we would
otherwise write ourselves on each platform. libuv types stay inside the I/O
layer (`vm/loop.c`, added in 7h, and the builtin files that use it), so a later swap to
raw epoll or io_uring stays local if measurements ever ask for it.

