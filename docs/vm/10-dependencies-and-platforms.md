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
| OpenSSL 3 | 7h | Dynamic by default, static as an option (10.0). `make vm` (`OPENSSL=system`) finds the system OpenSSL 3 with `pkg-config libssl libcrypto` and links `-lssl -lcrypto`; `make vm OPENSSL=static OPENSSL_PREFIX=/path` links `libssl.a` and `libcrypto.a` from that prefix by full path, searching only that prefix's `pkg-config` files, and fails rather than fall back to the system's shared libraries. Not vendored; see the note on OpenSSL under the license rule. |

License rule: vendored or statically linked third-party code must be MIT,
BSD, ISC, zlib, Apache-2.0 or similarly permissive (no copyleft). Its
license file stays with it (in the submodule) and ships with releases.
Where there is no license file, releases ship the notice extracted to one:
bdwgc's from its `README.QUICK`, like picohttpparser's from its header.
The notices that ship with the VM also include the Unicode License v3
notice for `vm/unicode_data.c`, which is generated from Unicode data.
OpenSSL 3 (Apache-2.0) is permissive too, but it is singled out for two
reasons: Apache-2.0 adds an attribution duty (its `LICENSE.txt`, and a
`NOTICE` file if one is present; OpenSSL 3.0 to 3.5 have none), and the
default build does not ship it at all, since it is linked dynamically. It
is linked statically only in release artifacts that include its
`LICENSE.txt` (10.0). Agentica itself is `Apache-2.0 WITH LLVM-exception`,
and releases ship its `LICENSE` and `NOTICE` alongside the third-party
licenses.

### 10.0 Linking OpenSSL

The default build links OpenSSL 3 dynamically, so `dist/agentica-vm` needs
libc and `libssl.so.3`/`libcrypto.so.3`. All other libraries stay static.
The dynamic build is the default for local builds, CI and distro packages;
every downloadable release artifact (the `dist/` archive and the single
file) is built with `OPENSSL=static`, so it needs only glibc's own
libraries (libc, libm and the dynamic loader; on an older glibc baseline,
`docs/future/18-front-end-language.md` §18). The release baseline is Debian bookworm
or newer, whose `libssl-dev` has the OpenSSL 3 static archives (glibc
2.36); an older baseline would need a built OpenSSL prefix.

- `make vm` (default `OPENSSL=system`) finds the system OpenSSL 3 with
  `pkg-config libssl libcrypto` and links `-lssl -lcrypto`. A missing
  OpenSSL, or one older than 3.0, stops the build with a clear error.
- Why dynamic: security fixes come with the distro's `libssl.so.3`, with no
  VM release; the system OpenSSL knows its own CA store (`OPENSSLDIR`); the
  binary is smaller and CI does not build OpenSSL; we do not ship OpenSSL
  code, so its attribution duty does not apply (license rule above); and
  the OpenSSL 3.x ABI is stable.
- `make vm OPENSSL=static` links a static OpenSSL 3, for the release
  artifacts or minimal glibc images without OpenSSL (distroless, `scratch`
  style). musl (Alpine) needs its own build (`docs/future/18-front-end-language.md` §18); there the
  dynamic build with Alpine's `openssl-dev` works. If a musl artifact is
  ever released, it is static too (musl plus a static OpenSSL).
- `OPENSSL=static` needs `OPENSSL_PREFIX=/path`, a prefix with `libssl.a`
  and `libcrypto.a`; without it the build stops with an error. Debian's
  `libssl-dev` ships both archives, so CI and the release build use
  `OPENSSL_PREFIX=/usr` with the distro's own static archives and never
  build OpenSSL. Any other prefix works too (for example OpenSSL built with
  `no-shared`). There is no vendored OpenSSL submodule unless the release
  workflow needs one later.
- The static build must never link the system's shared OpenSSL by
  accident. Its recipe unsets `PKG_CONFIG_PATH` and sets
  `PKG_CONFIG_LIBDIR` to the prefix's `lib/pkgconfig`, `lib64/pkgconfig`
  and `lib/<multiarch>/pkgconfig` (multiarch from `$(CC) -print-multiarch`
  when it is not empty), which replaces `pkg-config`'s default search path.
  The build fails if `pkg-config --exists libssl libcrypto` fails there, or
  if `pkg-config --variable=libdir` for `libssl` or `libcrypto` is not
  inside `OPENSSL_PREFIX`. The VM links the two archives by full path, in
  that `libdir` (so the `.pc` files decide `lib`, `lib64` or the multiarch
  directory). The extra libraries come from libcrypto's `Libs.private`
  (`pkg-config --static --libs-only-l --libs-only-other libssl
  libcrypto`): each `-lX` that is not part of glibc is linked as `libX.a`
  by full path, found through `pkg-config` in the same environment, and a
  missing one is a build error. Nothing is hard-coded; on Debian trixie,
  for example, `libcrypto.a` needs `-lz -lzstd` (from `zlib1g-dev` and
  `libzstd-dev`). Only glibc's own flags (such as `-ldl`, `-pthread`,
  `-lm`) stay as they are. The static CI or release job checks `readelf
  -d` of the VM against an allowlist: `NEEDED` may only name libc, libm and the dynamic loader
  (`ld-linux`), plus libpthread, libdl and librt on an old glibc.
- Both modes take `pkg-config --cflags libssl libcrypto` from the same
  `pkg-config` environment as their link flags.
- `pkg-config` never runs when the Makefile is parsed (no parse-time
  `$(shell pkg-config ...)`), so `make site`, `make dup-check` and the
  Racket-only tests do not need OpenSSL. The recipe for the
  `build/vm/flags` stamp runs `pkg-config` and writes the resolved cflags
  and link flags there, with `OPENSSL` and `OPENSSL_PREFIX`; the link
  recipe reads them back. A change of mode, prefix or flags relinks.
- The VM needs only OpenSSL 3.0.0 and loads with any 3.x. It calls only
  symbols of the `OPENSSL_3.0.0` version node; OpenSSL also has later
  nodes inside 3.0 (`OPENSSL_3.0.3`, `3.0.8`, `3.0.9`, for example
  `OPENSSL_strcasecmp`) and in 3.1 and later. `-DOPENSSL_API_COMPAT=30000`
  only hides deprecated API; what enforces the rule is a check in the
  normal dynamic CI `test` job, after `make vm`: it fails if
  `objdump -T dist/agentica-vm | rg -o 'OPENSSL_3\.[0-9.]+' | rg -v '^OPENSSL_3\.0\.0$'` prints anything. Newer features
  (Argon2id and `OSSL_set_max_threads` need 3.2) are found at run time: if
  `EVP_KDF_fetch` returns `NULL`, the call returns an error `Result` that
  names the missing feature.
- A static OpenSSL's built-in paths point at the build machine, so the
  static build finds the CA store itself (10.3).
- Static release artifacts ship OpenSSL's `LICENSE.txt` (and its `NOTICE`
  if a later version adds one), as the license rule above requires.
- Rejected for now: loading OpenSSL with `dlopen` only when a program uses
  TLS. It is more complex, so the default VM needs libssl even for programs
  without TLS. On purpose, then, without an OpenSSL development package the
  VM does not build and all VM tests skip locally; install `libssl-dev` to
  run them.

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

