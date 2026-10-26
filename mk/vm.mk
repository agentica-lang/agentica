# The C VM: sources, the build modes (release, SANITIZE, TSAN, GC_STRESS, TRACE), compile and link rules, ccache, the
# third-party libraries (yyjson, picohttpparser, libuv) and the system or vendored libgc and OpenSSL, with their cache keys.
# Included first: the variables here (VM_BUILD, VM_OBJ, OSSL_DEP, GC_DEP, ...) are read by the other files while make
# parses them. EXE is set by the root Makefile and set again here.

.PHONY: vm-openssl vm-openssl-key vm-third-party vm-third-party-key

# The C VM (docs/vm/11-build-ci-supply-chain.md section 11). On Linux libgc and OpenSSL are the system ones by default.
# make                    dist/agentica, the binary (the bootstrap below builds it)
# make vm-test            C tests in vm/tests/, run in parallel
# make windows-docker-build, windows-docker-check  the Windows cross build and check (see mk/windows.mk)
# make SANITIZE=1         clang with ASan and UBSan, no libgc: the same binary, built in that mode
# make TSAN=1             clang with TSan, no libgc (TSan and Boehm's stop-the-world do not mix): for make vm-tsan
# make vm-tsan            the C tests of the code that threads share (inbox, outcome, run queue, wake, job) under TSan
# make vm-tsan-run        the programs of tests/test_vm_multicore.py and the TCP, TLS and HTTP modules on
#                         several schedulers, on a TSan binary
# Each mode compiles vm/*.c and vm/jit/*.c once into build/vm/<mode>/obj/ (-MMD header dependencies) and links every binary from it.
# Compiles go through ccache when it is installed and its cache directory is writable (CCACHE= turns it off); CCACHE_BASEDIR is
# the checkout and the -g modes map it to . in debug info (-fdebug-prefix-map), so worktrees share hits.
# make TRACE=0            compile out the AGENTICA_VM_TRACE trace points
# make vm-fuzz            mutate compiled fixtures and run them
# make vm-libfuzz         the libFuzzer target (LIBFUZZ=1 mode: build/vm/libfuzz/agentica-vm-libfuzz, clang only)
# make vm-libfuzz-run     a bounded coverage-guided run from the compiled fixtures (see mk/vm-test.mk)
# make vm-gc-stress       GC-debug build that collects every 64 allocations, on the differential tests (sampled --max-steps sweep)
# make vm-lint            clang-tidy (19 or newer) over vm/*.c, vm/jit/*.c and vm/tests/*.c in the release, sanitizer and GC-stress configurations, files in parallel
# make vm-layers          the layer check of docs/vm/15-layers.md: each header compiles alone, the include and link rules hold, planted violations fail (Linux only)
# make AGENTICA_GC=vendored  build libgc from vm/third_party/bdwgc into build/vm/gc.o and link it statically (the release, the GC-stress build and
#                         non-Linux hosts do); pass it to every make command or export it. The Linux default AGENTICA_GC=system links the system
#                         libgc 8.2 or newer found by pkg-config (Debian: libgc-dev pkg-config) and checks it before any vm/*.c compile
#                         (the version, and a link test of GC_register_my_thread: the library must be built with thread support).
# make AGENTICA_OPENSSL=vendored  build OpenSSL from vm/third_party/openssl and link it statically (the release does); pass it to
#                         every make command or export it. The default AGENTICA_OPENSSL=system links the system OpenSSL 3 found by pkg-config
#                         (Debian: libssl-dev pkg-config) and checks it before any vm/*.c compile.
# make AGENTICA_ZLIB=vendored  build zlib from vm/third_party/zlib and link it statically (the release and non-Linux hosts do);
#                         pass it to every make command or export it. The Linux default AGENTICA_ZLIB=system links the system
#                         zlib found by pkg-config (Debian: zlib1g-dev pkg-config) and checks it before any vm/*.c compile.
# make vm-openssl         AGENTICA_OPENSSL=vendored: build only the static libraries; AGENTICA_OPENSSL=system: check the system OpenSSL
# make vm-openssl-key     AGENTICA_OPENSSL=vendored only: print what the OpenSSL build of this mode depends on (the CI cache key)
# make vm-third-party     build (AGENTICA_GC=vendored) or check (system) libgc, build (AGENTICA_ZLIB=vendored) or check (system) zlib,
#                         and build yyjson, picohttpparser, libuv and (Linux x86_64, Windows x64, macOS) libffi for this mode (no libgc with SANITIZE=1)
# make vm-third-party-key print what those builds depend on (the CI cache key); they rebuild only when it changes
GC_DIR := vm/third_party/bdwgc
YY_DIR := vm/third_party/yyjson
PICO_DIR := vm/third_party/picohttpparser
UV_DIR := vm/third_party/libuv
OSSL_DIR := vm/third_party/openssl
FFI_DIR := vm/third_party/libffi
ZLIB_DIR := vm/third_party/zlib
YY_DEFS := -DYYJSON_DISABLE_WRITER=1 -DYYJSON_DISABLE_INCR_READER=1 -DYYJSON_DISABLE_FILE=1 -DYYJSON_DISABLE_UTILS=1 -DYYJSON_DISABLE_NON_STANDARD=1 -DYYJSON_DISABLE_FAST_FP_CONV=1
# The vendored zlib build is codec-only (no configure, no gz* I/O): the eight sources deflate and inflate need.
ZLIB_NAMES := adler32 crc32 deflate inffast inflate inftrees trees zutil
VM_SRC := vm/value.c vm/text.c vm/map.c vm/list.c vm/unicode_data.c vm/loader.c vm/builtins.c vm/builtin_tables.c vm/strings.c vm/numbers.c vm/crypto.c vm/random.c vm/input.c vm/output.c vm/stdio_posix.c vm/stdio_windows.c vm/poll_posix.c vm/poll_windows.c vm/json.c vm/json_value.c vm/json_typed.c vm/loop.c vm/file_io.c vm/file_windows.c vm/files.c vm/zlib.c vm/zlib_codec.c vm/tree.c vm/stream.c vm/lazy.c vm/duplex.c vm/process.c vm/process_posix.c vm/process_windows.c vm/duplex_posix.c vm/duplex_windows.c vm/system.c vm/system_posix.c vm/system_windows.c vm/net_posix.c vm/net_windows.c vm/tcp.c vm/tls_openssl.c vm/tls_trust.c vm/tls_trust_posix.c vm/tls_trust_darwin.c vm/tls_trust_windows.c vm/digest_openssl.c vm/http_pico.c vm/http_body.c vm/http_fields.c vm/http_service.c vm/http_server.c vm/http_wire.c vm/logger.c vm/front_end.c vm/interp.c vm/task.c vm/runq.c vm/inbox.c vm/compute.c vm/sync.c vm/timers.c vm/task_map.c vm/channel.c vm/equal.c vm/testing.c vm/diag.c vm/trace.c vm/profile.c vm/ffi.c vm/ffi_libffi.c vm/ffi_none.c \
  vm/jit/jit.c vm/jit/emit_x64.c vm/jit/mem_posix.c vm/jit/mem_windows.c
EXE :=
VM_PIC := -fPIE
VM_PIE := -pie
VM_HARDEN_LDFLAGS := $(VM_PIE) -Wl,-z,relro,-z,now
VM_LIBS := -lpthread -lm
ifeq ($(VM_OS),Windows_NT)
ifeq ($(origin CC),default)
CC := gcc
endif
EXE := .exe
VM_PIC :=
VM_PIE :=
VM_HARDEN_LDFLAGS := -Wl,--dynamicbase,--nxcompat,--high-entropy-va
VM_LIBS :=
else ifeq ($(shell uname -s),Darwin)
VM_PIE :=
VM_HARDEN_LDFLAGS :=
# The system trust store (vm/tls_trust_darwin.c).
VM_LIBS += -framework Security -framework CoreFoundation
endif
UV_NAMES :=
AGENTICA_GC_DEFAULT := vendored
AGENTICA_ZLIB_DEFAULT := vendored
ifeq ($(VM_OS),Windows_NT)
UV_NAMES := fs-poll idna inet random strscpy strtok thread-common threadpool timer uv-common uv-data-getter-setters version \
  win/async win/core win/detect-wakeup win/dl win/error win/fs win/fs-event win/getaddrinfo win/getnameinfo win/handle \
  win/loop-watcher win/pipe win/thread win/poll win/process win/process-stdio win/signal win/snprintf win/stream \
  win/tcp win/tty win/udp win/util win/winapi win/winsock
VM_LIBS += -lpsapi -luser32 -ladvapi32 -liphlpapi -luserenv -lws2_32 -ldbghelp -lole32 -lshell32 -lsynchronization -lntdll
# Crypt32: the system trust store (vm/tls_trust_windows.c); with GDI32, what a static libcrypto needs on MinGW.
VM_LIBS += -lcrypt32 -lgdi32
else ifeq ($(shell uname -s),Linux)
AGENTICA_GC_DEFAULT := system
AGENTICA_ZLIB_DEFAULT := system
UV_NAMES := fs-poll idna inet random strscpy strtok thread-common threadpool timer uv-common uv-data-getter-setters version \
  unix/async unix/core unix/dl unix/fs unix/getaddrinfo unix/getnameinfo unix/loop-watcher unix/loop unix/pipe unix/poll \
  unix/process unix/random-devurandom unix/signal unix/stream unix/tcp unix/thread unix/tty unix/udp \
  unix/linux unix/procfs-exepath unix/random-getrandom unix/random-sysctl-linux unix/proctitle
VM_LIBS += -ldl -lrt
else ifeq ($(shell uname -s),Darwin)
UV_NAMES := fs-poll idna inet random strscpy strtok thread-common threadpool timer uv-common uv-data-getter-setters version \
  unix/async unix/core unix/dl unix/fs unix/getaddrinfo unix/getnameinfo unix/loop-watcher unix/loop unix/pipe unix/poll \
  unix/process unix/random-devurandom unix/signal unix/stream unix/tcp unix/thread unix/tty unix/udp \
  unix/proctitle unix/bsd-ifaddrs unix/kqueue unix/random-getentropy unix/darwin-proctitle unix/darwin unix/fsevents
endif
AGENTICA_GC ?= $(AGENTICA_GC_DEFAULT)
AGENTICA_ZLIB ?= $(AGENTICA_ZLIB_DEFAULT)
PKG_CONFIG ?= pkg-config
GC_MIN := 8.2.0
# The codec needs inflateInit2 and deflateInit2 with windowBits 15 (zlib), -15 (raw) and 31 (gzip), inflate,
# deflate and their end calls: wrapper support in both directions dates from the 1.2 series, so 1.2.0 is the floor,
# not the latest release.
ZLIB_MIN := 1.2.0
ifeq ($(filter $(AGENTICA_GC),system vendored),)
$(error AGENTICA_GC must be system or vendored, not '$(AGENTICA_GC)')
endif
ifeq ($(filter $(AGENTICA_ZLIB),system vendored),)
$(error AGENTICA_ZLIB must be system or vendored, not '$(AGENTICA_ZLIB)')
endif
UV_DEFS := -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112
ifeq ($(VM_OS),Windows_NT)
UV_DEFS := -DWIN32_LEAN_AND_MEAN -D_WIN32_WINNT=0x0A00 -D_CRT_DECLARE_NONSTDC_NAMES=0
else ifeq ($(shell uname -s),Darwin)
UV_DEFS := -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_DARWIN_UNLIMITED_SELECT=1 -D_DARWIN_USE_64_BIT_INODE=1
endif
VM_WARN := -std=c11 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -DAGC_VERSION='"$(AGC_VERSION)"' -I $(YY_DIR)/src $(YY_DEFS) -I $(UV_DIR)/include -I $(PICO_DIR)
DEBUG_MAPS = -fdebug-prefix-map=$(CURDIR)=. $(if $(filter-out $(CURDIR),$(PWD)),$(if $(filter $(CURDIR),$(shell cd '$(PWD)' 2>/dev/null && pwd -P)),-fdebug-prefix-map=$(PWD)=.))
ifeq ($(LIBFUZZ),1)
# The sanitizer flags plus libFuzzer's coverage hooks on every VM object; only agentica-vm-libfuzz links the runtime.
# First in the chain, so LIBFUZZ=1 wins over a SANITIZE=1 in the environment (the CI sanitizer job sets it).
VM_CC := clang
VM_CFLAGS := $(VM_WARN) -O1 -g -fno-omit-frame-pointer -fsanitize=fuzzer-no-link,address,undefined -fno-sanitize-recover=all -DAGC_NO_GC
VM_LDFLAGS := -fsanitize=address,undefined $(VM_LIBS)
GC_MODE := none
VM_BUILD := build/vm/libfuzz
YY_CFLAGS := -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all
OSSL_CFLAGS := -g -fno-omit-frame-pointer
DEBUG_MAP := $(DEBUG_MAPS)
else ifeq ($(SANITIZE),1)
VM_CC := clang
VM_CFLAGS := $(VM_WARN) -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all -DAGC_NO_GC
VM_LDFLAGS := -fsanitize=address,undefined $(VM_LIBS)
GC_MODE := none
VM_BUILD := build/vm/sanitize
YY_CFLAGS := -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all
OSSL_CFLAGS := -g -fno-omit-frame-pointer
DEBUG_MAP := $(DEBUG_MAPS)
FUZZ_RUNS ?= 30000
else ifeq ($(TSAN),1)
VM_CC := clang
VM_CFLAGS := $(VM_WARN) -O1 -g -fno-omit-frame-pointer -fsanitize=thread -fno-sanitize-recover=all -DAGC_NO_GC
VM_LDFLAGS := -fsanitize=thread $(VM_LIBS)
GC_MODE := none
VM_BUILD := build/vm/tsan
YY_CFLAGS := -O1 -g -fno-omit-frame-pointer -fsanitize=thread -fno-sanitize-recover=all
OSSL_CFLAGS := -g -fno-omit-frame-pointer
DEBUG_MAP := $(DEBUG_MAPS)
FUZZ_RUNS ?= 30000
else ifeq ($(GC_STRESS),1)
VM_CC := $(CC)
VM_CFLAGS := $(VM_WARN) -O1 -g -DGC_DEBUG -DAGC_GC_STRESS $(VM_PIC)
VM_LDFLAGS := $(VM_PIE) $(VM_LIBS)
GC_MODE := vendored
VM_BUILD := build/vm/gcstress
YY_CFLAGS := -O1 -g $(VM_PIC)
OSSL_CFLAGS := -g
DEBUG_MAP := $(DEBUG_MAPS)
else
VM_CC := $(CC)
VM_CFLAGS := $(VM_WARN) -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 $(VM_PIC)
VM_LDFLAGS := $(VM_HARDEN_LDFLAGS) $(VM_LIBS)
GC_MODE := $(AGENTICA_GC)
VM_BUILD := build/vm/release
YY_CFLAGS := -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 $(VM_PIC)
OSSL_CFLAGS := -fstack-protector-strong -D_FORTIFY_SOURCE=2
FUZZ_RUNS ?= 100000
endif
# libffi for the native calls (vm/ffi_libffi.c), compiled from its sources like libuv, with the two headers that its
# configure script would write made by the rules below. The source list is the one libffi's configure.host gives for
# the compiler's target: Linux and macOS x86_64 (X86_64), Windows x64 (MinGW gcc, X86_WIN64: ffiw64.c and win64.S) and
# macOS arm64 (AARCH64: aarch64/ffi.c and sysv.S, with the trampoline table that configure.ac turns on for Apple arm64).
# Elsewhere (Linux arm64, Windows arm64) vm/ffi_none.c refuses a program with extern functions.
FFI_MACHINE := $(shell $(VM_CC) -dumpmachine 2>/dev/null)
FFI_APPLE := $(findstring -apple-darwin,$(FFI_MACHINE))
FFI_NAMES :=
FFI_TARGET := X86_64
FFI_DIR_TARGET := x86
FFI_LONG_DOUBLE := 1
FFI_TRAMPOLINE_TABLE := 0
ifneq ($(filter x86_64-%,$(FFI_MACHINE)),)
ifeq ($(VM_OS),Windows_NT)
FFI_NAMES := prep_cif types x86/ffiw64 x86/win64
FFI_TARGET := X86_WIN64
else ifneq ($(findstring -linux,$(FFI_MACHINE))$(FFI_APPLE),)
FFI_NAMES := prep_cif types x86/ffi64 x86/ffiw64 x86/unix64 x86/win64
endif
else ifneq ($(filter arm64-% aarch64-%,$(FFI_MACHINE)),)
ifneq ($(FFI_APPLE),)
FFI_NAMES := prep_cif types aarch64/ffi aarch64/sysv
FFI_TARGET := AARCH64
FFI_DIR_TARGET := aarch64
# long double is double on Apple arm64, so configure leaves HAVE_LONG_DOUBLE at 0.
FFI_LONG_DOUBLE := 0
FFI_TRAMPOLINE_TABLE := 1
endif
endif
ifeq ($(TRACE),0)
VM_CFLAGS += -DAGC_TRACE_BUILD=0
endif
VM_GC :=
GC_INC :=
GC_LINK :=
GC_DEP :=
ifeq ($(GC_MODE),vendored)
VM_GC := build/vm/gc.o
GC_INC := -I $(GC_DIR)/include
else ifeq ($(GC_MODE),system)
GC_INC := $(shell $(PKG_CONFIG) --cflags bdw-gc 2>/dev/null)
GC_LINK := $(shell $(PKG_CONFIG) --libs bdw-gc 2>/dev/null)
GC_DEP := $(VM_BUILD)/gc-system
endif
VM_CFLAGS += $(GC_INC)
VM_ZLIB :=
ZLIB_LINK :=
ZLIB_INC :=
ZLIB_DEP :=
ifeq ($(AGENTICA_ZLIB),vendored)
VM_ZLIB := $(VM_BUILD)/libzlib.a
VM_CFLAGS += -I $(ZLIB_DIR)
else
ZLIB_INC := $(shell $(PKG_CONFIG) --cflags zlib 2>/dev/null)
ZLIB_LINK := $(shell $(PKG_CONFIG) --libs zlib 2>/dev/null)
ZLIB_DEP := $(VM_BUILD)/zlib-system
VM_CFLAGS += $(ZLIB_INC)
endif
VM_STAMP := build/vm/flags
VM_TP_STAMP := $(VM_BUILD)/third-party-flags
GC_STAMP := build/vm/gc-flags
GC_COMPILE = $(CC) -std=c11 -O2 $(VM_PIC) -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION -DGC_THREADS -DGC_BUILTIN_ATOMIC -DPARALLEL_MARK -DTHREAD_LOCAL_ALLOC -I $(GC_DIR)/include
YY_COMPILE = $(VM_CC) -std=c11 $(YY_CFLAGS) $(YY_DEFS)
PICO_COMPILE = $(VM_CC) -std=c11 $(YY_CFLAGS)
UV_COMPILE = $(VM_CC) -std=gnu11 $(YY_CFLAGS) $(UV_DEFS) -I $(UV_DIR)/include -I $(UV_DIR)/src
FFI_INC = $(VM_BUILD)/ffi/include
FFI_COMPILE = $(VM_CC) -std=gnu11 $(YY_CFLAGS) -I $(FFI_INC) -I $(FFI_DIR)/include
ZLIB_COMPILE = $(VM_CC) -std=c11 $(YY_CFLAGS) -I $(ZLIB_DIR)
SUBMODULE_KEY = if [ "$$(git -C $(1) rev-parse --show-toplevel 2>/dev/null)" = '$(CURDIR)/$(1)' ]; then \
  git ls-tree HEAD $(1); git -C $(1) rev-parse HEAD; git -C $(1) diff --no-ext-diff --no-color --binary HEAD | cksum; \
  (cd $(1) && git ls-files -z -o --exclude-standard | xargs -0r cksum); \
  else echo 'no git checkout: $(1)'; find $(1) -type f ! -path '*/.git/*' -print0 | LC_ALL=C sort -z | xargs -0r cksum | cksum; fi
GC_SYSTEM_KEY = { $(PKG_CONFIG) --modversion bdw-gc 2>/dev/null; echo '$(GC_INC) $(GC_LINK)'; }
GC_KEY = { echo '$(GC_COMPILE)'; $(CC) --version 2>/dev/null | head -n 1; $(call SUBMODULE_KEY,$(GC_DIR)); }
ZLIB_SYSTEM_KEY = { $(PKG_CONFIG) --modversion zlib 2>/dev/null; echo '$(ZLIB_INC) $(ZLIB_LINK)'; }
ZLIB_KEY = { echo '$(ZLIB_COMPILE)'; $(VM_CC) --version 2>/dev/null | head -n 1; $(call SUBMODULE_KEY,$(ZLIB_DIR)); }
TP_KEY = { echo '$(shell uname -s) $(shell uname -m) $(OS)'; \
  echo '$(YY_COMPILE) | $(PICO_COMPILE) | $(UV_COMPILE) | $(UV_NAMES) | $(AR) rcs'; $(VM_CC) --version 2>/dev/null | head -n 1; \
  $(AR) --version 2>/dev/null | head -n 1; \
  echo '$(FFI_COMPILE) | $(FFI_NAMES) | $(FFI_TARGET) $(FFI_DIR_TARGET) $(FFI_LONG_DOUBLE) $(FFI_TRAMPOLINE_TABLE) $(FFI_APPLE)'; \
  echo 'zlib=$(AGENTICA_ZLIB) $(ZLIB_COMPILE) | $(ZLIB_NAMES) | $(ZLIB_LINK)'; \
  $(call SUBMODULE_KEY,$(YY_DIR)); $(call SUBMODULE_KEY,$(PICO_DIR)); $(call SUBMODULE_KEY,$(UV_DIR)); \
  $(if $(filter vendored,$(AGENTICA_ZLIB)),$(call SUBMODULE_KEY,$(ZLIB_DIR));) \
  $(if $(FFI_NAMES),$(call SUBMODULE_KEY,$(FFI_DIR));) }
ifeq ($(origin CCACHE),undefined)
CCACHE := $(shell c=$$(command -v ccache 2>/dev/null) || exit 0; d=$$($$c -k cache_dir 2>/dev/null) || d=$${CCACHE_DIR:-$$HOME/.ccache}; \
  while [ ! -d "$$d" ]; do d=$$(dirname "$$d"); done; [ -w "$$d" ] && echo $$c)
endif
export CCACHE_BASEDIR ?= $(CURDIR)
VM_OBJ := $(VM_BUILD)/obj
VM_OBJS := $(patsubst vm/%.c,$(VM_OBJ)/%.o,$(VM_SRC))
VM_OBJ_STAMP := $(VM_BUILD)/obj-flags
# The resources of agentica.exe (Windows only): the application manifest of vm/agentica.manifest, which declares
# longPathAware, compiled by windres. It replaces the default manifest that MinGW's gcc links, and keeps what that one says.
# WINDRES follows CC: x86_64-w64-mingw32-gcc gives x86_64-w64-mingw32-windres.
VM_RES := $(if $(filter Windows_NT,$(VM_OS)),$(VM_OBJ)/agentica-res.o)
WINDRES ?= $(patsubst %gcc,%windres,$(patsubst %clang,%windres,$(VM_CC)))
VM_YY := $(VM_BUILD)/yyjson.o
VM_PICO := $(VM_BUILD)/picohttpparser.o
ZLIB_OBJS := $(patsubst %,$(VM_BUILD)/zlib/%.o,$(ZLIB_NAMES))
VM_UV := $(if $(UV_NAMES),$(VM_BUILD)/libuv.a)
UV_OBJS := $(patsubst %,$(VM_BUILD)/uv/%.o,$(UV_NAMES))
VM_FFI := $(if $(FFI_NAMES),$(VM_BUILD)/libffi.a)
FFI_OBJS := $(patsubst %,$(VM_BUILD)/ffi/%.o,$(FFI_NAMES))
FFI_HEADERS := $(if $(FFI_NAMES),$(FFI_INC)/ffi.h $(FFI_INC)/fficonfig.h $(FFI_INC)/ffitarget.h)
ifneq ($(FFI_NAMES),)
VM_CFLAGS += -DAGC_FFI -I $(FFI_INC)
endif
OSSL_BUILD := $(VM_BUILD)/openssl
OSSL_STAMP := $(VM_BUILD)/openssl-flags
OSSL_OPTS := no-shared no-tests no-docs no-apps no-module no-dso no-engine no-legacy no-autoload-config no-async no-comp \
  no-ssl3 no-dtls no-srp no-quic no-ui-console no-cmp no-ts no-ct no-ocsp no-http no-deprecated
OSSL_TARGET :=
ifeq ($(VM_OS),Windows_NT)
OSSL_TARGET := mingw64
endif
OSSL_ENV := env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOVERRIDES -u CC -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS -u LDLIBS
OSSL_LAUNCH = $(CCACHE)
OSSL_CONFIGURE = $(OSSL_ENV) CC='$(strip $(OSSL_LAUNCH) $(VM_CC))' perl $(CURDIR)/$(OSSL_DIR)/Configure $(OSSL_TARGET) $(OSSL_OPTS) $(OSSL_CFLAGS)
OSSL_SUBMAKE = $(OSSL_ENV) make -C $(OSSL_BUILD) CC='$(strip $(OSSL_LAUNCH) $(VM_CC))' build_libs
OSSL_RECIPE = $(subst ','\'',$(subst $(CURDIR)/,,$(OSSL_CONFIGURE) | $(OSSL_SUBMAKE)))
OSSL_KEY = { echo '$(shell uname -s) $(shell uname -m) $(OS)'; echo '$(OSSL_RECIPE)'; \
  $(VM_CC) --version 2>/dev/null | head -n 1; cat $(OSSL_DIR)/VERSION.dat; \
  if [ "$$(git -C $(OSSL_DIR) rev-parse --show-toplevel 2>/dev/null)" = '$(CURDIR)/$(OSSL_DIR)' ]; then git -C $(OSSL_DIR) rev-parse HEAD; fi; }
AGENTICA_OPENSSL ?= system
OSSL_MIN := 3.0.0
VM_OSSL :=
OSSL_LINK :=
OSSL_INC :=
OSSL_DEP :=
ifneq ($(UV_NAMES),)
ifeq ($(AGENTICA_OPENSSL),vendored)
VM_OSSL := $(OSSL_BUILD)/libssl.a $(OSSL_BUILD)/libcrypto.a
OSSL_LINK := $(VM_OSSL)
OSSL_DEP := $(VM_OSSL)
OSSL_INC := -I $(OSSL_BUILD)/include -I $(OSSL_DIR)/include
else ifeq ($(AGENTICA_OPENSSL),system)
OSSL_LINK := $(shell $(PKG_CONFIG) --libs openssl 2>/dev/null)
OSSL_INC := $(shell $(PKG_CONFIG) --cflags openssl 2>/dev/null)
OSSL_DEP := $(VM_BUILD)/openssl-system
else
$(error AGENTICA_OPENSSL must be system or vendored, not '$(AGENTICA_OPENSSL)')
endif
endif
VM_CFLAGS += $(OSSL_INC)

$(VM_STAMP): FORCE
	@mkdir -p $(VM_BUILD) build/vm
	@echo '$(VM_CC) $(VM_CFLAGS) $(VM_LDFLAGS) openssl=$(AGENTICA_OPENSSL) $(OSSL_LINK) gc=$(GC_MODE) $(GC_LINK) zlib=$(AGENTICA_ZLIB) $(ZLIB_LINK)' > $@.$(notdir $(VM_BUILD)); \
	if cmp -s $@.$(notdir $(VM_BUILD)) $@; then rm -f $@.$(notdir $(VM_BUILD)); else mv $@.$(notdir $(VM_BUILD)) $@; fi

$(VM_OBJ_STAMP): FORCE
	@mkdir -p $(VM_BUILD)
	@{ echo '$(VM_CC) $(VM_CFLAGS) $(if $(VM_RES),$(WINDRES))'; $(VM_CC) --version 2>/dev/null | head -n 1; } > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(VM_OBJ)/tests/%.o: VM_OBJ_FLAGS := -U NDEBUG

$(VM_OBJ)/tls_openssl.o $(VM_OBJ)/digest_openssl.o: $(OSSL_DEP)

$(VM_OBJ)/zlib.o $(VM_OBJ)/zlib_codec.o: $(ZLIB_DEP)

$(VM_OBJ)/%.o: vm/%.c $(VM_OBJ_STAMP) | $(OSSL_DEP) $(GC_DEP) $(ZLIB_DEP)
	@mkdir -p $(dir $@)
	$(CCACHE) $(VM_CC) $(VM_CFLAGS) $(DEBUG_MAP) $(VM_OBJ_FLAGS) -MMD -MP -c $< -o $@

$(VM_OBJ)/agentica-res.o: vm/agentica.rc vm/agentica.manifest $(VM_OBJ_STAMP)
	@mkdir -p $(VM_OBJ)
	$(WINDRES) -I vm -O coff vm/agentica.rc $@

-include $(wildcard $(VM_OBJ)/*.d $(VM_OBJ)/jit/*.d $(VM_OBJ)/tests/*.d)

$(VM_TP_STAMP): FORCE
	@mkdir -p $(VM_BUILD)
	@$(TP_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(GC_STAMP): FORCE
	@mkdir -p build/vm
	@$(GC_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

vm-third-party-key:
	@echo 'libgc=$(GC_MODE)'
	@echo 'zlib=$(AGENTICA_ZLIB)'
	@$(TP_KEY)
	@$(if $(filter system,$(GC_MODE)),$(GC_SYSTEM_KEY),$(if $(VM_GC),$(GC_KEY),:))
	@$(if $(filter system,$(AGENTICA_ZLIB)),$(ZLIB_SYSTEM_KEY),$(if $(VM_ZLIB),$(ZLIB_KEY),:))

vm-third-party: $(GC_DEP) $(VM_GC) $(ZLIB_DEP) $(VM_YY) $(VM_PICO) $(VM_ZLIB) $(VM_UV) $(VM_FFI)

$(GC_DIR)/extra/gc.c:
	@echo "missing $(GC_DIR): run git submodule update --init" >&2; exit 1

build/vm/gc.o: $(GC_STAMP) | $(GC_DIR)/extra/gc.c
	@mkdir -p build/vm
	$(CCACHE) $(GC_COMPILE) -c $(GC_DIR)/extra/gc.c -o $@

$(VM_BUILD)/gc-system: FORCE
	@command -v $(PKG_CONFIG) >/dev/null || { echo "AGENTICA_GC=system needs pkg-config and the Boehm GC development files (Debian: apt install libgc-dev pkg-config), or build with AGENTICA_GC=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --exists bdw-gc || { echo "pkg-config cannot find bdw-gc: install the Boehm GC development files (Debian: apt install libgc-dev), or build with AGENTICA_GC=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --atleast-version=$(GC_MIN) bdw-gc || { echo "the VM needs libgc $(GC_MIN) or newer, pkg-config found $$($(PKG_CONFIG) --modversion bdw-gc); install a newer libgc-dev or build with AGENTICA_GC=vendored" >&2; exit 1; }
	@mkdir -p $(VM_BUILD)
	@probe=$(VM_BUILD)/gc-thread-probe.$$$$; \
	  printf '%s\n' '#define GC_THREADS' '#include <gc.h>' 'int main(void) { struct GC_stack_base b; GC_get_stack_base(&b); return GC_register_my_thread(&b); }' | $(VM_CC) -x c - $(GC_INC) $(GC_LINK) -o $$probe >/dev/null 2>&1; status=$$?; rm -f $$probe; \
	  [ $$status -eq 0 ] || { echo "the system libgc has no thread support (GC_register_my_thread does not link): the VM registers its threads with the collector; build with AGENTICA_GC=vendored" >&2; exit 1; }
	@$(GC_SYSTEM_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(YY_DIR)/src/yyjson.c:
	@echo "missing $(YY_DIR): run git submodule update --init" >&2; exit 1

$(VM_YY): $(VM_TP_STAMP) | $(YY_DIR)/src/yyjson.c
	@mkdir -p $(VM_BUILD)
	$(CCACHE) $(YY_COMPILE) $(DEBUG_MAP) -c $(YY_DIR)/src/yyjson.c -o $@

$(PICO_DIR)/picohttpparser.c:
	@echo "missing $(PICO_DIR): run git submodule update --init" >&2; exit 1

$(VM_PICO): $(VM_TP_STAMP) | $(PICO_DIR)/picohttpparser.c
	@mkdir -p $(VM_BUILD)
	$(CCACHE) $(PICO_COMPILE) $(DEBUG_MAP) -c $(PICO_DIR)/picohttpparser.c -o $@

$(ZLIB_DIR)/zlib.h:
	@echo "missing $(ZLIB_DIR): run git submodule update --init" >&2; exit 1

$(VM_BUILD)/zlib-system: FORCE
	@command -v $(PKG_CONFIG) >/dev/null || { echo "AGENTICA_ZLIB=system needs pkg-config and the zlib development files (Debian: apt install zlib1g-dev pkg-config), or build with AGENTICA_ZLIB=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --exists zlib || { echo "pkg-config cannot find zlib: install the zlib development files (Debian: zlib1g-dev), or build with AGENTICA_ZLIB=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --atleast-version=$(ZLIB_MIN) zlib || { echo "the VM needs zlib $(ZLIB_MIN) or newer, pkg-config found $$($(PKG_CONFIG) --modversion zlib); install a newer zlib1g-dev or build with AGENTICA_ZLIB=vendored" >&2; exit 1; }
	@mkdir -p $(VM_BUILD)
	@$(ZLIB_SYSTEM_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(VM_BUILD)/zlib/%.o: $(VM_TP_STAMP) | $(ZLIB_DIR)/zlib.h
	@mkdir -p $(dir $@)
	$(CCACHE) $(ZLIB_COMPILE) $(DEBUG_MAP) -c $(ZLIB_DIR)/$*.c -o $@

$(VM_BUILD)/libzlib.a: $(ZLIB_OBJS) | $(ZLIB_DIR)/zlib.h
	rm -f $@
	$(AR) rcs $@ $(ZLIB_OBJS)

$(UV_DIR)/src/uv-common.c:
	@echo "missing $(UV_DIR): run git submodule update --init" >&2; exit 1

$(VM_BUILD)/uv/%.o: $(VM_TP_STAMP) | $(UV_DIR)/src/uv-common.c
	@mkdir -p $(dir $@)
	$(CCACHE) $(UV_COMPILE) $(DEBUG_MAP) -c $(UV_DIR)/src/$*.c -o $@

$(VM_BUILD)/libuv.a: $(UV_OBJS) | $(UV_DIR)/src/uv-common.c
	rm -f $@
	$(AR) rcs $@ $(UV_OBJS)

$(FFI_DIR)/include/ffi.h.in:
	@echo "missing $(FFI_DIR): run git submodule update --init" >&2; exit 1

# What libffi's configure would find on Linux x86_64 with gcc or clang, on Windows x64 with MinGW gcc (no hidden
# symbols in PE objects) and on macOS with Apple clang (.private_extern in Mach-O assembly; clang's
# __USER_LABEL_PREFIX__ gives the leading underscore of C names): the version comes from configure.ac, so a submodule
# bump follows it.
$(FFI_INC)/ffi.h: $(VM_TP_STAMP) | $(FFI_DIR)/include/ffi.h.in
	@mkdir -p $(dir $@)
	version=$$(sed -n 's/^AC_INIT(\[libffi\],\[\([0-9.]*\)\].*/\1/p' $(FFI_DIR)/configure.ac); \
	  number=$$(echo "$$version" | awk -F. '{print $$1 * 10000 + $$2 * 100 + $$3}'); \
	  [ -n "$$version" ] || { echo "cannot read the libffi version from $(FFI_DIR)/configure.ac" >&2; exit 1; }; \
	  sed -e "s/@VERSION@/$$version/" -e 's/@TARGET@/$(FFI_TARGET)/g' -e 's/@HAVE_LONG_DOUBLE@/$(FFI_LONG_DOUBLE)/' \
	    -e "s/@FFI_VERSION_STRING@/$$version/" -e "s/@FFI_VERSION_NUMBER@/$$number/" \
	    -e 's/@FFI_EXEC_TRAMPOLINE_TABLE@/$(FFI_TRAMPOLINE_TABLE)/g' $(FFI_DIR)/include/ffi.h.in > $@.new && mv $@.new $@

$(FFI_INC)/ffitarget.h: $(VM_TP_STAMP) | $(FFI_DIR)/include/ffi.h.in
	@mkdir -p $(dir $@)
	cp $(FFI_DIR)/src/$(FFI_DIR_TARGET)/ffitarget.h $@

$(FFI_INC)/fficonfig.h: $(VM_TP_STAMP)
	@mkdir -p $(dir $@)
ifeq ($(VM_OS),Windows_NT)
	@printf '%s\n' '#define STDC_HEADERS 1' '#define HAVE_MEMCPY 1' '#define HAVE_LONG_DOUBLE 1' \
	  '#define HAVE_AS_X86_PCREL 1' '#define FFI_NO_RAW_API 1' \
	  '#ifdef LIBFFI_ASM' '#define FFI_HIDDEN(name)' '#else' '#define FFI_HIDDEN' '#endif' > $@
else ifneq ($(FFI_APPLE),)
	@printf '%s\n' '#define STDC_HEADERS 1' '#define HAVE_MEMCPY 1' '#define SYMBOL_UNDERSCORE 1' '#define FFI_NO_RAW_API 1' \
	  $(if $(filter X86_64,$(FFI_TARGET)),'#define HAVE_LONG_DOUBLE 1' '#define HAVE_AS_X86_PCREL 1') \
	  $(if $(filter 1,$(FFI_TRAMPOLINE_TABLE)),'#define FFI_EXEC_TRAMPOLINE_TABLE 1') \
	  '#ifdef LIBFFI_ASM' '#define FFI_HIDDEN(name) .private_extern name' '#else' \
	  '#define FFI_HIDDEN __attribute__ ((visibility ("hidden")))' '#endif' > $@
else
	@printf '%s\n' '#define STDC_HEADERS 1' '#define HAVE_MEMCPY 1' '#define HAVE_LONG_DOUBLE 1' \
	  '#define HAVE_AS_X86_PCREL 1' '#define HAVE_RO_EH_FRAME 1' '#define EH_FRAME_FLAGS "a"' '#define FFI_NO_RAW_API 1' \
	  '#ifdef LIBFFI_ASM' '#define FFI_HIDDEN(name) .hidden name' '#else' \
	  '#define FFI_HIDDEN __attribute__ ((visibility ("hidden")))' '#endif' > $@
endif

$(VM_BUILD)/ffi/%.o: $(FFI_DIR)/src/%.c $(FFI_HEADERS)
	@mkdir -p $(dir $@)
	$(CCACHE) $(FFI_COMPILE) $(DEBUG_MAP) -c $< -o $@

$(VM_BUILD)/ffi/%.o: $(FFI_DIR)/src/%.S $(FFI_HEADERS)
	@mkdir -p $(dir $@)
	$(CCACHE) $(FFI_COMPILE) $(DEBUG_MAP) -c $< -o $@

$(VM_BUILD)/libffi.a: $(FFI_OBJS)
	rm -f $@
	$(AR) rcs $@ $(FFI_OBJS)

$(VM_OBJ)/ffi_libffi.o: $(FFI_HEADERS)

$(OSSL_DIR)/VERSION.dat:
	@echo "missing $(OSSL_DIR): run git submodule update --init" >&2; exit 1

vm-openssl-key $(OSSL_STAMP): OSSL_LAUNCH :=

vm-openssl-key: $(OSSL_DIR)/VERSION.dat
	@test '$(AGENTICA_OPENSSL)' = vendored || { echo "vm-openssl-key describes the AGENTICA_OPENSSL=vendored build; run make -s vm-openssl-key AGENTICA_OPENSSL=vendored" >&2; exit 1; }
	@$(OSSL_KEY)

vm-openssl: $(OSSL_DEP)

$(VM_BUILD)/openssl-system: FORCE
	@command -v $(PKG_CONFIG) >/dev/null || { echo "AGENTICA_OPENSSL=system needs pkg-config and the OpenSSL 3 development files (Debian: apt install pkg-config libssl-dev), or build with AGENTICA_OPENSSL=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --exists openssl || { echo "pkg-config cannot find openssl: install the OpenSSL 3 development files (Debian: libssl-dev), or build with AGENTICA_OPENSSL=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --atleast-version=$(OSSL_MIN) openssl || { echo "the VM needs OpenSSL $(OSSL_MIN) or newer, pkg-config found $$($(PKG_CONFIG) --modversion openssl); install a newer libssl-dev or build with AGENTICA_OPENSSL=vendored" >&2; exit 1; }
	@mkdir -p $(VM_BUILD)
	@{ $(PKG_CONFIG) --modversion openssl; echo '$(OSSL_INC) $(OSSL_LINK)'; } > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(OSSL_STAMP): $(OSSL_DIR)/VERSION.dat FORCE
	@mkdir -p $(VM_BUILD)
	@$(OSSL_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(OSSL_BUILD)/libcrypto.a: $(OSSL_STAMP)
	@perl -MIPC::Cmd -MFile::Copy -e 1 2>/dev/null || { echo "building OpenSSL needs perl 5 with its core modules (Debian: perl)" >&2; exit 1; }
	rm -rf $(OSSL_BUILD)
	mkdir -p $(OSSL_BUILD)
	cd $(OSSL_BUILD) && $(OSSL_CONFIGURE) $(DEBUG_MAP) > configure.log 2>&1 || { cat configure.log; exit 1; }
	$(OSSL_SUBMAKE) -j $(JOBS) > $(OSSL_BUILD)/build.log 2>&1 || { tail -n 40 $(OSSL_BUILD)/build.log; exit 1; }
	touch $@

$(OSSL_BUILD)/libssl.a: $(OSSL_BUILD)/libcrypto.a
	@test -f $@ || { echo "$@ is missing: remove $(OSSL_BUILD) and rebuild" >&2; exit 1; }

VM_LINK_LIBS = $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_ZLIB) $(VM_UV) $(VM_FFI)
VM_LINK = $(VM_CC) -o $@ $(filter-out $(VM_LINK_LIBS),$(filter %.o,$^)) $(VM_LINK_LIBS) $(OSSL_LINK) $(GC_LINK) $(ZLIB_LINK) $(VM_LDFLAGS)
