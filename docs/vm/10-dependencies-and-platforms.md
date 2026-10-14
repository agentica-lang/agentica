## 10. Dependencies and platforms

The VM runs on Linux, macOS and Windows, always in the "C" locale. The Windows specifics are binary-mode stdio, UTF-8 arguments from `wmain`, `BCryptGenRandom`, `GetSystemTimePreciseAsFileTime` and `QueryPerformanceCounter`. Console rendering is outside the contract.

| Dependency | Choice |
|---|---|
| C compiler | C11, gcc or clang. Windows: MSYS2 UCRT64 gcc. No MSVC: it lacks `__builtin_*_overflow`, and one compiler family keeps one Makefile. |
| libc | Dynamic. A static glibc breaks NSS, and macOS forbids a static libc. |
| Boehm GC | Vendored submodule `vm/third_party/bdwgc`, tag v8.2.12. `make vm` compiles its single-file amalgamation (`extra/gc.c`) and links it statically. |
| yyjson | Vendored submodule `vm/third_party/yyjson` (MIT), tag 0.13.0. Only the reader is built, with the writer, file API, JSON Pointer and extensions disabled. The reader does not recurse and is fuzzed on OSS-Fuzz. It allocates with `malloc` and holds no GC pointers. The document is freed right after its copy into GC nodes (2.6). The encoder is our own (2.4), since yyjson formats floats and escapes differently. |
| libuv | Vendored submodule `vm/third_party/libuv` (MIT, with BSD-2-Clause and ISC parts in its `LICENSE-extra`), tag v1.53.0. Its Linux sources are built per build mode into `$(VM_BUILD)/uv/` and linked statically with `-ldl -lrt`. Linux only for now: macOS and Windows builds leave it out and have no file builtins. |
| picohttpparser | Vendored submodule `vm/third_party/picohttpparser` (dual MIT or Perl; we take MIT), tag v1.4. It parses and validates request and response heads behind our adapter (10.6). `phr_decode_chunked` is not used, since it knows no limits. It is built at the baseline, without `-msse4.2`. Its SSE4.2 path is a SIMD candidate (`docs/future/19-simd.md` §19). |
| OpenSSL 3.5 LTS | Vendored submodule `vm/third_party/openssl` (Apache-2.0), shallow, tag `openssl-3.5.9`. Linked statically in the release (`AGENTICA_OPENSSL=vendored`, 10.0). The default, `system`, links the system OpenSSL 3.0 or newer dynamically, so a fresh checkout does not spend minutes building OpenSSL. Only `vm/tls_openssl.c` includes OpenSSL headers (10.3). |

Every submodule is pinned to a release tag and upgraded only by a reviewed PR that bumps it (11).

**License rule.** Vendored or statically linked third-party code must be MIT, BSD, ISC, zlib, Apache-2.0 or similarly permissive. No copyleft. Its license file stays in the submodule and ships with releases. Where there is no license file, releases ship the notice extracted to one (bdwgc's from `README.QUICK`, picohttpparser's from its header). The VM also ships the Unicode License v3 notice for `vm/unicode_data.c`. Releases ship OpenSSL's `LICENSE.txt` in `licenses/openssl/`, since OpenSSL is Apache-2.0 and the VM links it statically. Agentica is `Apache-2.0 WITH LLVM-exception`, and releases ship its `LICENSE` and `NOTICE` with the third-party licenses.

### 10.0 Building and linking OpenSSL

`AGENTICA_OPENSSL` picks the OpenSSL build.

- **`system`** (the default) links the system OpenSSL dynamically, with the flags of `pkg-config --cflags --libs openssl`. The stamp `$(VM_BUILD)/openssl-system` runs before any `vm/*.c` compile. It stops with a clear message when `pkg-config` or the package is missing, or when the version is older than `OSSL_MIN` (3.0.0). `vm/tls_openssl.c` also stops with `#error` on an older OpenSSL or on LibreSSL. The stamp holds the version and flags, so a new system OpenSSL relinks. No Perl and no cache are involved.
- **`vendored`** builds the pinned submodule and links it statically. The release uses it, so the shipped VM needs only glibc's own libraries (`readelf -d` shows no `libssl` or `libcrypto`) and runs on any glibc 2.28 system. Every CI job uses `system`, except that the `test` job links one vendored release-mode binary from a cached OpenSSL, so this path stays tested (11).

The mode is not remembered. Pass `AGENTICA_OPENSSL=vendored` to every make command, or export it. `build/vm/flags` records the mode, so switching it relinks the VM.

The vendored build:

- Configure runs out of tree in `$(VM_BUILD)/openssl/` with the mode's compiler (`VM_CC`: `cc`, `clang` for `SANITIZE=1`, `zig cc` in the release), then `make build_libs`. The parent make's `MAKEFLAGS`, `CC`, `CFLAGS`, `LDFLAGS` and similar variables are cleared with `env -u`, so nothing from the parent leaks in. The output goes to `configure.log` and `build.log`. It needs Perl 5 with its core modules (`IPC::Cmd`; on Debian the `perl` package). The rule stops with a clear message when they are missing.
- Options (`OSSL_OPTS` in the Makefile): `no-shared no-tests no-docs no-apps`, no loadable code (`no-module no-dso no-engine`), no legacy provider, no automatic `openssl.cnf` loading, no parts TLS does not use, and `no-deprecated`, so only the 3.x API is visible. The libraries are PIC, so the PIE link works.
- Flags per mode: the release adds `-fstack-protector-strong -D_FORTIFY_SOURCE=2`; the GC-stress mode adds `-g`; the sanitizer mode builds with clang and `-g -fno-omit-frame-pointer` but without `-fsanitize`. An instrumented OpenSSL would make the sanitizer job much slower. ASan still wraps OpenSSL's `memcpy` and friends, so an overflow into a buffer the VM hands to OpenSSL is still caught.
- The stamp `$(VM_BUILD)/openssl-flags` holds the Configure and sub-make command lines, the compiler version, `VERSION.dat` and the submodule commit. A change to any of them rebuilds. The libraries depend only on the stamp, not on source times, so toggling `TRACE` or touching sources never rebuilds OpenSSL. libgc, yyjson, picohttpparser and libuv follow the same model (11). `make vm-openssl` builds only the libraries. After editing OpenSSL sources by hand, remove `$(VM_BUILD)/openssl`.
- Headers: `vm/*.c` see the generated headers through `-I`. Only `vm/tls_openssl.c` includes them.
- Initialization uses `OPENSSL_INIT_NO_LOAD_CONFIG | OPENSSL_INIT_NO_ATEXIT`. The built-in `OPENSSLDIR` points at the build machine, and the VM may end with `_exit` while a pool thread still runs. Contexts set TLS 1.2 and security level 2 as minimums.
- `--version` prints `OpenSSL_version(OPENSSL_VERSION_STRING)`.
- Bumping: check out the new 3.5.x tag inside `vm/third_party/openssl`, `git add` it and rebuild. The changed `VERSION.dat` changes the stamp and the CI keys. Then rerun the TLS, sanitizer and diff tests. Moving to the next LTS line is a reviewed change of its own.
- Rejected: loading OpenSSL with `dlopen` only when a program uses TLS. It is more complex, and the static build costs only about 6 MB more for `dist/agentica-vm`.
- The vendored build is Linux only for now. macOS and Windows leave OpenSSL out, and `vm/tls_openssl.c` has stubs there.

### 10.1 Event loop: libuv, not libevent

- libevent would need a hand-written process layer on Windows, helper threads that relay pipe and console reads into the loop, and a separate file path. It has no file I/O with timeouts and no UTF-8 paths on Windows, and no spawn with stdio pipes. libuv has `uv_spawn`, `uv_pipe_t` on IOCP, `uv_tty_t`, `uv_fs_*` on a thread pool and `uv_getaddrinfo`. The gap blocks `Process`, stdin and `File` on Windows, so the choice is libuv.
- libuv has no TLS. We drive OpenSSL through memory BIOs, which costs about 200 lines.
- libuv also stays for multicore (10.2.3). We do not replace it with raw epoll or io_uring. The model of §16 has one loop on the I/O thread, with the thread pool beside it. libuv types stay inside the I/O layer (`vm/loop.c` and the builtin files that use it), so a later swap stays local if measurements ask for it.
