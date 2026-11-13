## 10. Dependencies and platforms

The single binary embeds its front end and `std/` sources in ELF (Linux),
Mach-O (macOS Intel and ARM) or COFF (Windows). Native compiler bootstrap,
fixed-point and command-line checks live in `platforms.yml`. Windows uses
MSYS2 UCRT64 GCC to build a native `.exe`; MSYS2 is a build environment, not
the interpreter of the resulting program.

The network runs on Windows as on Linux: TCP, TLS and `std/http` (client and
server) use the same libuv sockets and the same C helpers, with no Windows-only
HTTP code.

The release links every third-party library statically; the build modes and
the release are in §11.

Each submodule under `vm/third_party/` is pinned to a release commit and
upgraded only by a reviewed PR; `git submodule status` shows the pin.

- **C compiler:** C11, gcc or clang. Windows: MSYS2 UCRT64 gcc. No MSVC: it
  lacks `__builtin_*_overflow`, and one compiler family keeps one Makefile.
- **libc:** dynamic. A static glibc breaks NSS, and macOS forbids a static libc.
- **Boehm GC** (`bdwgc`): the vendored mode compiles its single-file
  amalgamation (`extra/gc.c`); the system mode needs libgc 8.2.0 or newer
  (§11).
- **yyjson:** only the reader is built, with the writer, file API, JSON Pointer
  and extensions disabled. The reader does not recurse and is fuzzed on
  OSS-Fuzz. It allocates with `malloc` and holds no GC pointers. In the
  `AGC_NO_GC` build (sanitizer and fuzz), `vm/json.c` routes its allocations
  through `agc_alloc_atomic`, so its documents count toward the fuzzer's 256 MB
  limit (11, Fuzzing). In the GC build the document is freed right after its
  copy into GC nodes (2.6). The encoder is our own (2.4), since yyjson formats
  floats and escapes differently.
- **libuv:** the source list of the target system is built per mode into
  `$(VM_BUILD)/uv/` and linked statically.
- **picohttpparser:** parses and validates request and response heads behind
  our adapter (10.6). `phr_decode_chunked` is not used, since it knows no
  limits. It is built at the baseline, without `-msse4.2`; its SSE4.2 path is a
  SIMD candidate (`docs/future/19-simd.md` §19).
- **libffi:** calls the C functions of `extern` blocks. The sources that
  libffi's `configure.host` lists for the target are compiled per mode into
  `$(VM_BUILD)/ffi/`, with the `ffi.h` and `fficonfig.h` that its configure
  script would write made by `mk/vm.mk`, and linked statically. Only
  `vm/ffi_libffi.c` includes `ffi.h`.
- **zlib:** the vendored mode builds only the codec side, without configure and
  without the `gz*` file API; the system mode needs zlib 1.2.0 or newer (§11).
  Only `vm/zlib_codec.c` includes `zlib.h` (15.5).
- **OpenSSL 3.5 LTS** in the release; the system mode takes OpenSSL 3.0 or
  newer, so a fresh checkout does not spend minutes building OpenSSL (§11,
  10.0). Only the adapter files (`vm/tls_openssl.c`,
  `vm/digest_openssl.c`, `vm/tls_trust*.c`) include OpenSSL headers (10.3). A
  feature that only 3.5 has (Argon2id, `OSSL_set_max_threads`) is not always
  there: adding one means raising `OSSL_MIN` of `mk/vm.mk` and the `#error` in
  `vm/tls_openssl.c` to 3.5, or checking at run time on system builds and
  returning an error `Result` that names the missing feature. An algorithm that
  a system build leaves out (a FIPS-only OpenSSL has no MD5, SHA-1 or scrypt)
  stops the call with `RUNTIME-INTERNAL`. The crypto API has no low-level
  primitives (no raw block ciphers, no ECB, no unauthenticated modes); the one
  exception is Triple DES CBC with CMAC, for payment formats.

**License rule.** Vendored or statically linked third-party code must be MIT,
BSD, ISC, zlib, Apache-2.0 or similarly permissive. No copyleft. Its license
file stays in the submodule and ships with releases. Where there is no license
file, releases ship the notice extracted to one (bdwgc's from `README.QUICK`,
picohttpparser's from its header). The VM also ships the Unicode License v3
notice for `vm/unicode_data.c`. Releases ship OpenSSL's `LICENSE.txt` in
`licenses/openssl/`, since OpenSSL is Apache-2.0 and the VM links it statically.
Agentica is `Apache-2.0 WITH LLVM-exception`, and releases ship its `LICENSE`
and `NOTICE` with the third-party licenses.

### 10.0 Building and linking OpenSSL

The modes (`AGENTICA_OPENSSL`) are in §11. `vm/tls_openssl.c` stops with
`#error` on an older OpenSSL or on LibreSSL.

The vendored build (`mk/vm.mk`, `OSSL_OPTS`, the source of the flags):

- Configure runs out of tree in `$(VM_BUILD)/openssl/` with the mode's compiler
  and the parent's `MAKEFLAGS`, `CC`, `CFLAGS` and `LDFLAGS` cleared. It needs
  Perl 5. Static, PIC libraries, `no-deprecated`, no legacy provider and no
  automatic `openssl.cnf` loading.
- The sanitizer mode builds OpenSSL with clang and `-g -fno-omit-frame-pointer`
  but without `-fsanitize`: an instrumented OpenSSL would make the sanitizer job
  much slower. ASan still wraps OpenSSL's `memcpy` and friends, so an overflow
  into a buffer the VM hands to OpenSSL is still caught.
- The libraries depend only on the stamp (`$(VM_BUILD)/openssl-flags`: command
  lines, compiler version, `VERSION.dat`, submodule commit), not on source
  times. After editing OpenSSL sources by hand, remove `$(VM_BUILD)/openssl`.
- Initialization uses `OPENSSL_INIT_NO_LOAD_CONFIG | OPENSSL_INIT_NO_ATEXIT`:
  the built-in `OPENSSLDIR` points at the build machine, and the VM may end with
  `_exit` while a pool thread still runs. Contexts set TLS 1.2 and security
  level 2 as minimums.
- Bumping: check out the new 3.5.x tag inside `vm/third_party/openssl`,
  `git add` it and rebuild, then rerun the TLS, sanitizer and diff tests. The
  next LTS line is a reviewed change of its own.
- Rejected: loading OpenSSL with `dlopen` only when a program uses TLS. It is
  more complex, and the static build costs only about 6 MB more.

### 10.1 Event loop: libuv, not libevent

- libevent would need a hand-written process layer on Windows, helper threads
  that relay pipe and console reads into the loop, and a separate file path. It
  has no file I/O with timeouts and no UTF-8 paths on Windows, and no spawn with
  stdio pipes. libuv has `uv_spawn`, `uv_pipe_t` on IOCP, `uv_tty_t`, `uv_fs_*`
  on a thread pool and `uv_getaddrinfo`. The gap blocks `Process`, stdin and
  `File` on Windows, so the choice is libuv.
- libuv has no TLS. We drive OpenSSL through memory BIOs, which costs about 200
  lines.
- libuv also stays for multicore (10.2.3). We do not replace it with raw epoll
  or io_uring. The model of §16 has one loop on the I/O thread, with the thread
  pool beside it. libuv types stay inside the I/O layer (`vm/loop.c` and the
  builtin files that use it), so a later swap stays local if measurements ask
  for it.
