JOBS ?= $(shell nproc 2>/dev/null || echo 4)
TESTS ?= tests/
TESTS_EXPLICIT = $(if $(filter file,$(origin TESTS)),,1)
# The platform the VM is built for: the host, or a cross target. `make windows-docker-check` sets it to Windows_NT on a
# Linux host, which selects the Windows sources, libraries, linker flags and embedded object format. `OS` is Windows_NT
# on Windows and empty elsewhere, so the default is the host.
VM_OS ?= $(OS)
# The words a recipe puts before a program it built but cannot run itself: empty on the host and on Windows, `wine` in
# the container of `make windows-docker-check`, which runs the Windows programs it builds.
RUN_PROGRAM ?=
# What runs one C test binary, the word xargs puts before each path: `env` on the host, `wine` in that container (env
# would be taken for the program to run).
VM_TEST_RUNNER ?= env
EXE := $(if $(filter Windows_NT,$(VM_OS)),.exe)
PRODUCT := dist/agentica$(EXE)
unexport AGENTICA_VM_TRACE AGENTICA_VM_TRACE_FILE AGENTICA_FLUSH_TIMEOUT_MS
VM_DIFF_TESTS = $(sort $(wildcard tests/test_vm_diff_*.py))

# `make` builds the product, dist/agentica: the VM with the front end inside (docs/future/18-front-end-language.md §18.2 and
# §18.8). It needs only a C toolchain: the bootstrap below starts from bootstrap/stage0.agcb. The host is the default
# target; `make windows-docker-check` cross-builds the Windows VM on a Linux or macOS host with docker (VM_OS below).
.DEFAULT_GOAL := all

.PHONY: all agentica test test-slow test-py tests tests-host tests-files tests-docker tests-wine test-cli test-distribution clean test-bdd smoke goldens bench eval-references version vm-test vm-test-binaries docker-test-image windows-docker-image windows-docker-wrappers windows-docker-build windows-docker-check windows-docker-remove-check windows-docker-remove-wine-check test-remove-actions vm-latency vm-task-map vm-fuzz stage1 stage2 stage3 stage0 fixed-point vm-gc-stress vm-trace-off vm-tsan vm-layers vm-diff-build vm-diff-test vm-golden-check sweep-full vm-sanitize-build vm-sanitize-test vendored-check vendored-test vm-openssl vm-openssl-key vm-third-party vm-third-party-key site site-serve site-sass dup-check dup-baseline FORCE

all: $(PRODUCT)

agentica: $(PRODUCT)

# Targets that step 8d-2 removed. They fail on purpose: without a rule, `make vm` would find the vm/ folder and say nothing to do.
.PHONY: vm exe cli bdd-driver
vm exe cli bdd-driver:
	@echo "make $@ is gone: the product is one binary, dist/agentica (the VM with the front end); run make" >&2; exit 1

# A recipe that fails leaves no half-written target for the next make to take as up to date. The stages below also remove
# their output before they write it, so a compiler that exits 0 without writing cannot pass for the previous file.
.DELETE_ON_ERROR:

# The version is the one line of the VERSION file (C gets it as AGC_VERSION).
version:
	@printf '%s' '$(AGC_VERSION)'

# Tests live in tests/test_<area>.py and run through pytest; unittest.TestCase modules remain supported.
# TESTS names modules, or directories that hold them (the default is tests/). Design: references/ci.md,
# docs/future/18-front-end-language.md §18.7.
# Fast Python tests:           make test [TESTS="tests/test_vm_bits.py ..."]
# Test groups:                 make tests KIND=fast|files|slow|all [DOCKER=1|WINE=1]
# More or fewer workers:       make test JOBS=8
PYTHON ?= python3
POETRY ?= poetry
# TESTS without a leading ./ or a trailing /. A directory contributes its own test_*.py files, not those of subdirectories
# (tests/eval/test_*.py are not part of this runner).
TESTS_NORM = $(patsubst %/,%,$(patsubst ./%,%,$(TESTS)))
PY_FILES = $(filter %.py,$(TESTS_NORM))
# Modules that only run when named (make vm-latency, make vm-task-map): a directory in TESTS does not pick them up
PY_ALONE = tests/test_vm_latency.py tests/test_vm_task_map.py
ISOLATED_PY_TESTS = tests/test_vm_os_remove.py tests/test_bdd_cleanup.py tests/test_windows_filesystem_safety.py
PY_ISOLATED_SELECTED = $(filter $(ISOLATED_PY_TESTS),$(PY_FILES))
PY_TESTS = $(sort $(filter-out $(ISOLATED_PY_TESTS),$(PY_FILES)) $(filter-out $(PY_ALONE) $(ISOLATED_PY_TESTS),$(foreach t,$(filter-out %.py,$(TESTS_NORM)),$(wildcard $(t)/test_*.py))))
# A file that is not tests/test_<area>.py (a file of another kind, or a .py file elsewhere) would build a wrong module name below
PY_NOT_DIR = $(foreach t,$(filter-out %.py,$(TESTS_NORM)),$(if $(wildcard $(t)/.),,$(t)))
PY_BAD = $(PY_NOT_DIR) $(filter-out tests/test_%.py,$(PY_FILES)) $(foreach f,$(filter tests/test_%.py,$(PY_FILES)),$(if $(findstring /,$(f:tests/%=%)),$(f)))
PY_CHECK = $(if $(strip $(PY_BAD)),$(error TESTS: $(strip $(PY_BAD)) is not a tests/test_<area>.py file))
# AGENTICA_TEST_SLOW= keeps a stray flag in the environment from turning this into a slow run.
test: $(PRODUCT)
	@: $(PY_CHECK)
	@$(MAKE) --no-print-directory test-py AGENTICA_TEST_SLOW=

# The slow tier: @slow TestCase methods and pytest functions marked slow. CI runs it after make test; locally do not run it.
test-slow: $(PRODUCT)
	@: $(PY_CHECK)
	@$(MAKE) --no-print-directory test-py AGENTICA_TEST_SLOW=1

# Hang guards, innermost first: the limit of one test (tests/agentica_test.py), then this limit of one test module,
# then the timeout-minutes of the job in ci.yml. Seconds, times AGENTICA_TEST_TIMEOUT_SCALE (default 1),
# which also stretches the deadlines inside the tests. The slow tier gets the longer base.
MODULE_BASE_LIMIT = $(if $(filter-out 0,$(AGENTICA_TEST_SLOW)),1800,600)
MODULE_LIMIT = $(shell awk -v scale='$(or $(AGENTICA_TEST_TIMEOUT_SCALE),1)' -v base=$(MODULE_BASE_LIMIT) 'BEGIN { printf "%d", base * scale }')

# One pytest process per module, run by make itself: -j gives the workers, -O (GNU make 4.0 or newer) keeps each
# module's output together, -k runs the other modules after a failure. CI requires Poetry; locally system pytest is a
# fallback when Poetry is unavailable, and tests skip only if both runners are missing.
test-py:
	@: $(PY_CHECK)
	@if [ -n "$(PY_ISOLATED_SELECTED)" ]; then \
	  echo "$(PY_ISOLATED_SELECTED) is isolated: run make tests KIND=files (Docker) or make test-remove-actions in CI" >&2; exit 1; \
	fi
	@if [ -n "$(PY_TESTS)" ]; then \
	  if command -v $(POETRY) >/dev/null 2>&1; then \
	    pytest_runner="$(POETRY) run python -m pytest"; \
	  elif [ -n "$$CI" ]; then \
	    echo "$(POETRY) is required in CI" >&2; exit 1; \
	  elif python3 -m pytest --version >/dev/null 2>&1; then \
	    pytest_runner="python3 -m pytest"; \
	  else \
	    echo "SKIP the Python tests: $(POETRY) and system pytest are unavailable"; exit 0; \
	  fi; \
	  $(MAKE) --no-print-directory -k -O -j$(JOBS) PYTEST_RUNNER="$$pytest_runner" \
	    $(addprefix py-test/,$(PY_TESTS)) \
	    || { echo "The Python tests failed" >&2; exit 1; }; \
	fi

# `timeout` (coreutils) ends a hung module: exit 124, or 137 when it had to send KILL after the 10 s of grace. Without
# the command the module runs unguarded; the per-test limit and the job timeout remain.
PYTEST_RUNNER ?= $(POETRY) run python -m pytest
py-test/%: FORCE
	@echo "pytest $*"
	@if command -v timeout >/dev/null 2>&1; then \
	  timeout -k 10 $(MODULE_LIMIT) $(PYTEST_RUNNER) "$*"; status=$$?; \
	  if [ $$status -eq 124 ] || [ $$status -eq 137 ]; then \
	    echo "pytest $*: hung, stopped after $(MODULE_LIMIT) s (the module limit)" >&2; \
	  fi; \
	  exit $$status; \
	else $(PYTEST_RUNNER) "$*"; fi

# The tests that run the product command line on dist/agentica (make test runs them too, with the rest): the options, the
# diagnostics, the programs, `agentica test`, `agentica run`.
CLI_TESTS ?= tests/test_cli_forms.py tests/test_examples.py tests/test_filesystem.py tests/test_process.py tests/test_source_paths.py \
  tests/test_source_utf8.py tests/test_bdd.py tests/test_modules.py tests/test_vm_diff_8.py tests/test_single_binary.py
test-cli: $(PRODUCT)
	AGENTICA_TEST_EXECUTABLE="$(CURDIR)/$(PRODUCT)" $(MAKE) --no-print-directory test-py TESTS="$(CLI_TESTS)" AGENTICA_TEST_SLOW=

# Speed check (docs/vm-benchmarks.md): make bench BENCH_ARGS="--runs 3 --size 2"
bench: $(PRODUCT)
	python3 benchmarks/run.py $(BENCH_ARGS)

eval-references:
	python3 tests/eval/run.py --check-references --jobs 8

# Task wake latency next to busy tasks (docs/vm/10-io-scheduler.md 10.2.1), alone so it has the CPU to itself
vm-latency: $(PRODUCT)
	@$(MAKE) --no-print-directory test-py TESTS=tests/test_vm_latency.py

# The timing cases of Task.map (docs/future/27-iteration-and-concurrency.md 27.1), alone for the same reason
vm-task-map: $(PRODUCT)
	@$(MAKE) --no-print-directory test-py TESTS=tests/test_vm_task_map.py

# The test groups (references/ci.md): make tests KIND=fast|files|slow|all, DOCKER=1, WINE=1
#   fast   the default tier, the same as make test
#   files  the filesystem-destructive cases: the local Docker sandbox, or the Actions scratch in CI
#   slow   the @slow cases, the same as make test-slow
#   all    fast, then slow, then files
# DOCKER=1 puts the group in the Ubuntu test container; WINE=1 runs the Windows checks of it under Wine.
# TESTS= narrows only a host fast/slow selection; it is rejected with files, all, Docker or Wine.
KIND ?= fast
DOCKER ?=
WINE ?=

tests:
	@case "$(KIND)" in fast|files|slow|all) ;; *) echo "make tests: KIND must be fast, files, slow or all (got '$(KIND)')" >&2; exit 2 ;; esac
	@if [ -n "$(DOCKER)" ] && [ -n "$(WINE)" ]; then \
	  echo "make tests: choose either DOCKER=1 or WINE=1, not both" >&2; exit 2; \
	fi
	@if [ -n "$(TESTS_EXPLICIT)" ] && { [ -n "$(DOCKER)" ] || [ -n "$(WINE)" ] || [ "$(KIND)" = files ] || [ "$(KIND)" = all ]; }; then \
	  echo "make tests: TESTS= is supported only with KIND=fast or slow on the host" >&2; exit 2; \
	fi
	@if [ -n "$(WINE)" ]; then $(MAKE) --no-print-directory tests-wine KIND=$(KIND); \
	elif [ -n "$(DOCKER)" ]; then $(MAKE) --no-print-directory tests-docker KIND=$(KIND); \
	else $(MAKE) --no-print-directory tests-host KIND=$(KIND); fi

# A group on the host. `files` is never one: it always goes through Docker or the Actions scratch.
tests-host:
	@case "$(KIND)" in \
	  fast) $(MAKE) --no-print-directory test ;; \
	  slow) $(MAKE) --no-print-directory test-slow ;; \
	  files) $(MAKE) --no-print-directory tests-files ;; \
	  all) $(MAKE) --no-print-directory test && $(MAKE) --no-print-directory test-slow && \
	       $(MAKE) --no-print-directory tests-files ;; \
	esac

# The destructive group: only the Actions scratch of an ephemeral runner, or the local Docker sandbox.
tests-files:
	@if [ "$${GITHUB_ACTIONS:-}" = true ]; then $(POETRY) run python tools/run_remove_actions.py all; \
	else $(MAKE) --no-print-directory tests-docker KIND=files; fi

# A group in the Ubuntu test container: the checkout is read-only there and build/ and dist/ are own volumes.
tests-docker: docker-test-image
	tools/docker-tests.sh --image "$(TEST_IMAGE)" --mode $(KIND)

# The Windows group under Wine: the cross build runs first and the tests run in the Windows image.
tests-wine:
	@case "$(KIND)" in \
	  fast) $(MAKE) --no-print-directory windows-docker-check ;; \
	  files) $(MAKE) --no-print-directory windows-docker-build && \
	         tools/docker-tests.sh --image "$(WINDOWS_IMAGE)" --mode windows-wine-tests ;; \
	  *) echo "make tests WINE=1 runs KIND=fast or KIND=files" >&2; exit 2 ;; \
	esac

test-bdd: $(if $(filter true,$(GITHUB_ACTIONS)),$(PRODUCT))
	@if [ "$${GITHUB_ACTIONS:-}" = true ]; then \
	  $(PYTHON) tools/run_remove_actions.py bdd; \
	else \
	  $(MAKE) --no-print-directory docker-test-image && \
	  tools/docker-tests.sh --image "$(TEST_IMAGE)" --mode bdd; \
	fi

# Example smoke runs on dist/agentica, in parallel (tests/smoke.sh).
smoke: $(PRODUCT)
	tests/smoke.sh

# ci.yml, sweep.yml and the release tests run their checks as the targets below, so the same command works locally.

# The built binary, copied away from the checkout, still imports its std/ modules
test-distribution: $(PRODUCT)
	AGENTICA_TEST_EXECUTABLE=$(CURDIR)/$(PRODUCT) $(MAKE) --no-print-directory test-py TESTS=tests/test_stdlib_distribution.py

# make goldens FIXTURES="name ..." rewrites only those fixtures (names without .agc)
# Without FIXTURES it also rewrites the CLI output golden tests/fixtures/cli/forms.json (tests/test_cli_forms.py) and the
# front-end goldens of tests/fixtures/frontend/ from the Agentica stages (tools/refreeze.py, fast tier only: run
# `poetry run python tools/refreeze.py` with no flag to rewrite the frozen manifests of the slow tier too, slow).
goldens: $(PRODUCT)
	AGENTICA_FIXTURES="$(FIXTURES)" $(PYTHON) -m tests.vm_diff_support
	AGENTICA_FIXTURES="$(FIXTURES)" $(PYTHON) -m tests.test_vm_stack
	test -n "$(FIXTURES)" || $(POETRY) run python -m tests.test_cli_forms freeze
	test -n "$(FIXTURES)" || $(POETRY) run python tools/refreeze.py --fast-only

# make vm-golden-check FIXTURES="name ..." runs the golden check of CI on only those fixtures
vm-golden-check: $(PRODUCT)
	AGENTICA_FIXTURES="$(FIXTURES)" $(PYTHON) -m tests.vm_diff_support check

JSCPD ?= tools/jscpd/node_modules/.bin/jscpd

tools/jscpd/node_modules: tools/jscpd/package.json tools/jscpd/package-lock.json
	npm ci --prefix tools/jscpd --ignore-scripts --no-audit --no-fund
	touch $@

dup-check: tools/jscpd/node_modules
	$(JSCPD) --baseline .jscpd-baseline.json --fail-on-new-clones

dup-baseline: tools/jscpd/node_modules
	$(JSCPD) --baseline .jscpd-baseline.json --update-baseline --reporters silent

clean:
	rm -rf dist build site/public site/resources

DART_SASS ?= $(HOME)/.local/opt/dart-sass

site site-serve site-sass: export PATH := $(DART_SASS):$(PATH)
site site-serve: export HUGO_PARAMS_VERSION = $(AGC_VERSION)

site-sass:
	@command -v sass >/dev/null || { echo "The site needs Dart Sass: put its sass on PATH or in $(DART_SASS) (pinned version in .github/workflows/pages.yml)" >&2; exit 1; }

site: site-sass
	hugo --cleanDestinationDir --source site --panicOnWarning $(HUGO_FLAGS)

site-serve: site-sass
	hugo server --source site

# The C VM (docs/vm/11-build-ci-supply-chain.md section 11). On Linux libgc and OpenSSL are the system ones by default.
# make                    dist/agentica, the binary (the bootstrap below builds it)
# make vm-test            C tests in vm/tests/, run in parallel
# make windows-docker-build  cross-build dist/agentica.exe and the C test binaries with llvm-mingw + Wine
# make windows-docker-check  also run the C tests and the Windows CI fast Python modules through Wine
#                           (WINDOWS_TEST_MODULES="tests/test_foo.py ..." selects other fast modules)
# make SANITIZE=1         clang with ASan and UBSan, no libgc: the same binary, built in that mode
# make TSAN=1             clang with TSan, no libgc (TSan and Boehm's stop-the-world do not mix): for make vm-tsan
# make vm-tsan            the C tests of the code that threads share (inbox, outcome, run queue, wake, job) under TSan
# Each mode compiles vm/*.c once into build/vm/<mode>/obj/ (-MMD header dependencies) and links every binary from it.
# Compiles go through ccache when it is installed and its cache directory is writable (CCACHE= turns it off); CCACHE_BASEDIR is
# the checkout and the -g modes map it to . in debug info (-fdebug-prefix-map), so worktrees share hits.
# make TRACE=0            compile out the AGENTICA_VM_TRACE trace points
# make vm-fuzz            mutate compiled fixtures and run them
# make vm-gc-stress       GC-debug build that collects every 64 allocations, on the differential tests (sampled --max-steps sweep)
# make vm-lint            clang-tidy (19 or newer) over vm/*.c and vm/tests/*.c in the release, sanitizer and GC-stress configurations, files in parallel
# make vm-layers          the layer check of docs/vm/15-layers.md: each header compiles alone, the include and link rules hold, planted violations fail (Linux only)
# make AGENTICA_GC=vendored  build libgc from vm/third_party/bdwgc into build/vm/gc.o and link it statically (the release, the GC-stress build and
#                         non-Linux hosts do); pass it to every make command or export it. The Linux default AGENTICA_GC=system links the system
#                         libgc 8.2 or newer found by pkg-config (Debian: libgc-dev pkg-config) and checks it before any vm/*.c compile
#                         (the version, and a link test of GC_register_my_thread: the library must be built with thread support).
# make AGENTICA_OPENSSL=vendored  build OpenSSL from vm/third_party/openssl and link it statically (the release does); pass it to
#                         every make command or export it. The default AGENTICA_OPENSSL=system links the system OpenSSL 3 found by pkg-config
#                         (Debian: libssl-dev pkg-config) and checks it before any vm/*.c compile.
# make vm-openssl         AGENTICA_OPENSSL=vendored: build only the static libraries; AGENTICA_OPENSSL=system: check the system OpenSSL
# make vm-openssl-key     AGENTICA_OPENSSL=vendored only: print what the OpenSSL build of this mode depends on (the CI cache key)
# make vm-third-party     build (AGENTICA_GC=vendored) or check (system) libgc, and build yyjson, picohttpparser and libuv for this mode (no libgc with SANITIZE=1)
# make vm-third-party-key print what those builds depend on (the CI cache key); they rebuild only when it changes
AGC_VERSION := $(shell cat VERSION)
GC_DIR := vm/third_party/bdwgc
YY_DIR := vm/third_party/yyjson
PICO_DIR := vm/third_party/picohttpparser
UV_DIR := vm/third_party/libuv
OSSL_DIR := vm/third_party/openssl
YY_DEFS := -DYYJSON_DISABLE_WRITER=1 -DYYJSON_DISABLE_INCR_READER=1 -DYYJSON_DISABLE_FILE=1 -DYYJSON_DISABLE_UTILS=1 -DYYJSON_DISABLE_NON_STANDARD=1 -DYYJSON_DISABLE_FAST_FP_CONV=1
VM_SRC := vm/value.c vm/text.c vm/map.c vm/list.c vm/unicode_data.c vm/loader.c vm/builtins.c vm/builtin_tables.c vm/strings.c vm/numbers.c vm/random.c vm/input.c vm/output.c vm/stdio_posix.c vm/stdio_windows.c vm/json.c vm/json_value.c vm/json_typed.c vm/loop.c vm/file_io.c vm/file_windows.c vm/files.c vm/tree.c vm/stream.c vm/duplex.c vm/process.c vm/system.c vm/tcp.c vm/tls_openssl.c vm/http_pico.c vm/http_body.c vm/http_fields.c vm/http_client.c vm/http_server.c vm/logger.c vm/front_end.c vm/interp.c vm/task.c vm/runq.c vm/inbox.c vm/sync.c vm/task_map.c vm/channel.c vm/equal.c vm/testing.c vm/diag.c vm/trace.c
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
endif
UV_NAMES :=
AGENTICA_GC_DEFAULT := vendored
ifeq ($(VM_OS),Windows_NT)
UV_NAMES := fs-poll idna inet random strscpy strtok thread-common threadpool timer uv-common uv-data-getter-setters version \
  win/async win/core win/detect-wakeup win/dl win/error win/fs win/fs-event win/getaddrinfo win/getnameinfo win/handle \
  win/loop-watcher win/pipe win/thread win/poll win/process win/process-stdio win/signal win/snprintf win/stream \
  win/tcp win/tty win/udp win/util win/winapi win/winsock
VM_LIBS += -lpsapi -luser32 -ladvapi32 -liphlpapi -luserenv -lws2_32 -ldbghelp -lole32 -lshell32 -lsynchronization -lntdll
else ifeq ($(shell uname -s),Linux)
AGENTICA_GC_DEFAULT := system
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
PKG_CONFIG ?= pkg-config
GC_MIN := 8.2.0
ifeq ($(filter $(AGENTICA_GC),system vendored),)
$(error AGENTICA_GC must be system or vendored, not '$(AGENTICA_GC)')
endif
UV_DEFS := -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112
ifeq ($(VM_OS),Windows_NT)
UV_DEFS := -DWIN32_LEAN_AND_MEAN -D_WIN32_WINNT=0x0A00 -D_CRT_DECLARE_NONSTDC_NAMES=0
else ifeq ($(shell uname -s),Darwin)
UV_DEFS := -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_DARWIN_UNLIMITED_SELECT=1 -D_DARWIN_USE_64_BIT_INODE=1
endif
VM_WARN := -std=c11 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -DAGC_VERSION='"$(AGC_VERSION)"' -I $(YY_DIR)/src $(YY_DEFS) -I $(UV_DIR)/include -I $(PICO_DIR)
DEBUG_MAPS = -fdebug-prefix-map=$(CURDIR)=. $(if $(filter-out $(CURDIR),$(PWD)),$(if $(filter $(CURDIR),$(shell cd '$(PWD)' 2>/dev/null && pwd -P)),-fdebug-prefix-map=$(PWD)=.))
ifeq ($(SANITIZE),1)
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
VM_STAMP := build/vm/flags
VM_TP_STAMP := $(VM_BUILD)/third-party-flags
GC_STAMP := build/vm/gc-flags
GC_COMPILE = $(CC) -std=c11 -O2 $(VM_PIC) -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION -DGC_THREADS -DGC_BUILTIN_ATOMIC -DPARALLEL_MARK -DTHREAD_LOCAL_ALLOC -I $(GC_DIR)/include
YY_COMPILE = $(VM_CC) -std=c11 $(YY_CFLAGS) $(YY_DEFS)
PICO_COMPILE = $(VM_CC) -std=c11 $(YY_CFLAGS)
UV_COMPILE = $(VM_CC) -std=gnu11 $(YY_CFLAGS) $(UV_DEFS) -I $(UV_DIR)/include -I $(UV_DIR)/src
SUBMODULE_KEY = if [ "$$(git -C $(1) rev-parse --show-toplevel 2>/dev/null)" = '$(CURDIR)/$(1)' ]; then \
  git ls-tree HEAD $(1); git -C $(1) rev-parse HEAD; git -C $(1) diff --no-ext-diff --no-color --binary HEAD | cksum; \
  (cd $(1) && git ls-files -z -o --exclude-standard | xargs -0r cksum); \
  else echo 'no git checkout: $(1)'; find $(1) -type f ! -path '*/.git/*' -print0 | LC_ALL=C sort -z | xargs -0r cksum | cksum; fi
GC_SYSTEM_KEY = { $(PKG_CONFIG) --modversion bdw-gc 2>/dev/null; echo '$(GC_INC) $(GC_LINK)'; }
GC_KEY = { echo '$(GC_COMPILE)'; $(CC) --version 2>/dev/null | head -n 1; $(call SUBMODULE_KEY,$(GC_DIR)); }
TP_KEY = { echo '$(shell uname -s) $(shell uname -m) $(OS)'; \
  echo '$(YY_COMPILE) | $(PICO_COMPILE) | $(UV_COMPILE) | $(UV_NAMES) | $(AR) rcs'; $(VM_CC) --version 2>/dev/null | head -n 1; \
  $(AR) --version 2>/dev/null | head -n 1; \
  $(call SUBMODULE_KEY,$(YY_DIR)); $(call SUBMODULE_KEY,$(PICO_DIR)); $(call SUBMODULE_KEY,$(UV_DIR)); }
ifeq ($(origin CCACHE),undefined)
CCACHE := $(shell c=$$(command -v ccache 2>/dev/null) || exit 0; d=$$($$c -k cache_dir 2>/dev/null) || d=$${CCACHE_DIR:-$$HOME/.ccache}; \
  while [ ! -d "$$d" ]; do d=$$(dirname "$$d"); done; [ -w "$$d" ] && echo $$c)
endif
export CCACHE_BASEDIR ?= $(CURDIR)
VM_OBJ := $(VM_BUILD)/obj
VM_OBJS := $(patsubst vm/%.c,$(VM_OBJ)/%.o,$(VM_SRC))
VM_OBJ_STAMP := $(VM_BUILD)/obj-flags
VM_YY := $(VM_BUILD)/yyjson.o
VM_PICO := $(VM_BUILD)/picohttpparser.o
VM_UV := $(if $(UV_NAMES),$(VM_BUILD)/libuv.a)
UV_OBJS := $(patsubst %,$(VM_BUILD)/uv/%.o,$(UV_NAMES))
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
	@echo '$(VM_CC) $(VM_CFLAGS) $(VM_LDFLAGS) openssl=$(AGENTICA_OPENSSL) $(OSSL_LINK) gc=$(GC_MODE) $(GC_LINK)' > $@.$(notdir $(VM_BUILD)); \
	if cmp -s $@.$(notdir $(VM_BUILD)) $@; then rm -f $@.$(notdir $(VM_BUILD)); else mv $@.$(notdir $(VM_BUILD)) $@; fi

$(VM_OBJ_STAMP): FORCE
	@mkdir -p $(VM_BUILD)
	@{ echo '$(VM_CC) $(VM_CFLAGS)'; $(VM_CC) --version 2>/dev/null | head -n 1; } > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(VM_OBJ)/tests/%.o: VM_OBJ_FLAGS := -U NDEBUG

$(VM_OBJ)/tls_openssl.o: $(OSSL_DEP)

$(VM_OBJ)/%.o: vm/%.c $(VM_OBJ_STAMP) | $(OSSL_DEP) $(GC_DEP)
	@mkdir -p $(dir $@)
	$(CCACHE) $(VM_CC) $(VM_CFLAGS) $(DEBUG_MAP) $(VM_OBJ_FLAGS) -MMD -MP -c $< -o $@

-include $(wildcard $(VM_OBJ)/*.d $(VM_OBJ)/tests/*.d)

$(VM_TP_STAMP): FORCE
	@mkdir -p $(VM_BUILD)
	@$(TP_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(GC_STAMP): FORCE
	@mkdir -p build/vm
	@$(GC_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

vm-third-party-key:
	@echo 'libgc=$(GC_MODE)'
	@$(TP_KEY)
	@$(if $(filter system,$(GC_MODE)),$(GC_SYSTEM_KEY),$(if $(VM_GC),$(GC_KEY),:))

vm-third-party: $(GC_DEP) $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV)

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

$(UV_DIR)/src/uv-common.c:
	@echo "missing $(UV_DIR): run git submodule update --init" >&2; exit 1

$(VM_BUILD)/uv/%.o: $(VM_TP_STAMP) | $(UV_DIR)/src/uv-common.c
	@mkdir -p $(dir $@)
	$(CCACHE) $(UV_COMPILE) $(DEBUG_MAP) -c $(UV_DIR)/src/$*.c -o $@

$(VM_BUILD)/libuv.a: $(UV_OBJS) | $(UV_DIR)/src/uv-common.c
	rm -f $@
	$(AR) rcs $@ $(UV_OBJS)

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

VM_LINK_LIBS = $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV)
VM_LINK = $(VM_CC) -o $@ $(filter-out $(VM_LINK_LIBS),$(filter %.o,$^)) $(VM_LINK_LIBS) $(OSSL_LINK) $(GC_LINK) $(VM_LDFLAGS)

# The binary and its bootstrap (docs/future/18-front-end-language.md §18.2 and §18.8; docs/vm/08-loader-and-cli.md). The front end is
# compiler/front_end.agc, a program that the binary carries as data. Each stage is its .agcb, in build/stage/. The seed is
# bootstrap/stage0.agcb, a stage2 that was checked in (make stage0 refreshes it):
#   first binary  linked with stage0 and the std/ sources of this checkout (build/vm/<mode>/bootstrap/agentica)
#   stage1  compiled by the first binary
#   stage2  compiled by the first binary with stage1 as its front end (--front-end)
#   stage3  compiled by the first binary with stage2 as its front end; it must be stage2, byte for byte
#   dist/agentica  linked with stage2: the product, carrying stage2 and the two programs of `agentica test` (below)
# make fixed-point        the above, then dist/agentica compiles the front end and the two programs again; that must be the same bytes
# make stage0             refresh bootstrap/stage0.agcb from stage2, after the fixed point holds (references/ci.md)
# The stages are the same bytes in every mode (release, SANITIZE=1, ...): a mode builds its own first binary, and runs the stages
# again only when one of their inputs changed. The GC stress build is the exception: it links the stage2 that the release mode
# built, because compiling under it would collect every 64 allocations.
STAGE_DIR := build/stage
FRONT_END_SRC := compiler/front_end.agc
STD_NAMES := $(shell cat stdlib/MODULES)
STD_FILES := $(addprefix stdlib/,$(STD_NAMES))
# compiler/agentica.toml is not an input: it holds the style rules for the style test, and compile never reads it.
STAGE_INPUTS := $(wildcard compiler/*.agc) stdlib/MODULES $(STD_FILES) VERSION
# The runner and the default step program of `agentica test` (compiler/bdd_driver.agc), compiled at build time with the front
# end of this build and carried by the binary, so `agentica test` does not compile them on every run. The first binary has
# none (stage2 does not exist yet): its front end is stage0, whose driver compiles them from the std/ sources on every
# `agentica test`, as it always did, and its `run --embedded` exits 2 (tests/test_bdd.py).
EMBEDDED_PROGRAMS := $(STAGE_DIR)/runner.agcb $(STAGE_DIR)/steps.agcb
STAGE0 := bootstrap/stage0.agcb
BOOT := $(VM_BUILD)/bootstrap/agentica$(EXE)
# The compiler that makes stage1: the first binary. make stage0 STAGE1_COMPILER=... names another one when stage0 cannot
# compile the current compiler/ (a binary built from the parent commit).
STAGE1_COMPILER ?= $(BOOT)
STAGE1_NEEDS := $(if $(filter $(BOOT),$(STAGE1_COMPILER)),$(BOOT))

ifeq ($(GC_STRESS),1)
$(STAGE_DIR)/stage2.agcb $(EMBEDDED_PROGRAMS):
	@echo "$@ is missing: the GC stress build links the front end of the release build; run make first" >&2; exit 1
else
$(STAGE_DIR)/stage1.agcb: $(STAGE_INPUTS) $(STAGE1_NEEDS)
	@mkdir -p $(STAGE_DIR)
	rm -f $@
	$(RUN_PROGRAM) $(STAGE1_COMPILER) compile $(FRONT_END_SRC) -o $@ || { \
	  echo "STAGE1_COMPILER ($(STAGE1_COMPILER)) cannot compile $(FRONT_END_SRC)." >&2; \
	  echo "If it is the first binary, linked from $(STAGE0), then $(STAGE0) may be too old for this change (or the VM no longer loads it):" >&2; \
	  echo "run make stage0 STAGE1_COMPILER=<a binary that can compile compiler/>, as references/ci.md says" >&2; exit 1; }

$(STAGE_DIR)/stage2.agcb: $(STAGE_DIR)/stage1.agcb $(STAGE_INPUTS) $(BOOT)
	rm -f $@
	$(RUN_PROGRAM) $(BOOT) --front-end $< compile $(FRONT_END_SRC) -o $@

$(STAGE_DIR)/stage3.agcb: $(STAGE_DIR)/stage2.agcb $(STAGE_INPUTS) $(BOOT)
	rm -f $@
	$(RUN_PROGRAM) $(BOOT) --front-end $< compile $(FRONT_END_SRC) -o $@
	cmp $(STAGE_DIR)/stage2.agcb $@ || { echo "fixed point: stage2 and stage3 differ" >&2; exit 1; }

# The first binary compiles them with stage2 as its front end, as it compiled stage3: the bytes are the ones dist/agentica
# makes (make fixed-point checks that).
$(EMBEDDED_PROGRAMS): $(STAGE_DIR)/%.agcb: compiler/embedded/%.agc $(STAGE_DIR)/stage2.agcb stdlib/MODULES $(STD_FILES) VERSION $(BOOT)
	rm -f $@
	$(RUN_PROGRAM) $(BOOT) --front-end $(STAGE_DIR)/stage2.agcb compile $< -o $@
endif

stage1: $(STAGE_DIR)/stage1.agcb
stage2: $(STAGE_DIR)/stage2.agcb
stage3: $(STAGE_DIR)/stage3.agcb

# The object format of the embedded data, for the cross build (vm/tools/gen-embedded.sh). Empty lets the script pick
# the format of the host.
EMBEDDED_FORMAT :=
ifeq ($(VM_OS),Windows_NT)
EMBEDDED_FORMAT := coff
endif

# The generated assembly carries the format, so a switch between the host and a cross target has to regenerate it even
# though its inputs did not change: the stamp holds the format and follows the pattern of the other flags stamps.
EMBEDDED_STAMP := $(VM_BUILD)/embedded-format

$(EMBEDDED_STAMP): FORCE
	@mkdir -p $(VM_BUILD)
	@printf '%s\n' '$(EMBEDDED_FORMAT)' > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

# The front end and the std/ sources go into the binary through a generated assembly file with .incbin (not through ccache,
# which cannot see the files that .incbin reads).
$(VM_BUILD)/embedded.s: vm/tools/gen-embedded.sh stdlib/MODULES $(STAGE_DIR)/stage2.agcb $(EMBEDDED_PROGRAMS) $(STD_FILES) $(EMBEDDED_STAMP)
	@mkdir -p $(VM_BUILD)
	AGENTICA_OBJECT_FORMAT=$(EMBEDDED_FORMAT) sh vm/tools/gen-embedded.sh $(STAGE_DIR)/stage2.agcb stdlib stdlib/MODULES $(EMBEDDED_PROGRAMS) > $@

$(VM_BUILD)/bootstrap/embedded.s: vm/tools/gen-embedded.sh stdlib/MODULES $(STAGE0) $(STD_FILES) $(EMBEDDED_STAMP)
	@mkdir -p $(VM_BUILD)/bootstrap
	AGENTICA_OBJECT_FORMAT=$(EMBEDDED_FORMAT) sh vm/tools/gen-embedded.sh $(STAGE0) stdlib stdlib/MODULES > $@

$(VM_OBJ)/embedded.o: $(VM_BUILD)/embedded.s $(VM_OBJ_STAMP) $(STAGE_DIR)/stage2.agcb $(EMBEDDED_PROGRAMS) $(STD_FILES)
	@mkdir -p $(VM_OBJ)
	$(VM_CC) -x assembler -c $< -o $@

$(VM_OBJ)/embedded-stage0.o: $(VM_BUILD)/bootstrap/embedded.s $(VM_OBJ_STAMP) $(STAGE0) $(STD_FILES)
	@mkdir -p $(VM_OBJ)
	$(VM_CC) -x assembler -c $< -o $@

AGENTICA_OBJS = $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/agentica.o $(VM_OBJ)/launch.o $(VM_LINK_LIBS) $(VM_STAMP)

$(BOOT): $(AGENTICA_OBJS) $(VM_OBJ)/embedded-stage0.o
	@mkdir -p $(dir $@)
	$(VM_LINK)

# stage3 is only checked, not linked: order-only, so a stage3 that was rebuilt to the same bytes relinks nothing.
dist/agentica$(EXE): $(AGENTICA_OBJS) $(VM_OBJ)/embedded.o | $(STAGE_DIR)/stage3.agcb
	@mkdir -p dist
	$(VM_LINK)

# The same binary in the build folder of the mode, for a mode that must not replace dist/agentica (make vm-gc-stress).
$(VM_BUILD)/agentica$(EXE): $(AGENTICA_OBJS) $(VM_OBJ)/embedded.o
	$(VM_LINK)

fixed-point: $(STAGE_DIR)/stage3.agcb dist/agentica$(EXE)
	rm -f $(STAGE_DIR)/stage4.agcb
	$(RUN_PROGRAM) dist/agentica$(EXE) compile $(FRONT_END_SRC) -o $(STAGE_DIR)/stage4.agcb
	cmp $(STAGE_DIR)/stage2.agcb $(STAGE_DIR)/stage4.agcb || { echo "fixed point: dist/agentica compiles another front end" >&2; exit 1; }
	for name in runner steps; do \
	  rm -f $(STAGE_DIR)/$$name-check.agcb; \
	  $(RUN_PROGRAM) dist/agentica$(EXE) compile compiler/embedded/$$name.agc -o $(STAGE_DIR)/$$name-check.agcb; \
	  cmp $(STAGE_DIR)/$$name.agcb $(STAGE_DIR)/$$name-check.agcb || { echo "fixed point: dist/agentica compiles another $$name" >&2; exit 1; }; \
	done

# A new stage0 is the stage2 of a checkout where the fixed point holds. The next make rebuilds everything from it.
stage0: $(STAGE_DIR)/stage3.agcb
	cp $(STAGE_DIR)/stage2.agcb $(STAGE0)

VM_TESTS := $(patsubst vm/tests/%_test.c,$(VM_BUILD)/%-test$(EXE),$(wildcard vm/tests/*_test.c))
.SECONDARY: $(patsubst vm/tests/%.c,$(VM_OBJ)/tests/%.o,$(wildcard vm/tests/*_test.c))

$(VM_BUILD)/%-test$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/tests/%_test.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

# This test interposes enumeration by compiling the Windows adapter in its own translation unit.
$(VM_BUILD)/windows_remove-test$(EXE): $(OSSL_DEP) $(GC_DEP) $(filter-out $(VM_OBJ)/file_windows.o,$(VM_OBJS)) $(VM_OBJ)/fuzz.o $(VM_OBJ)/tests/windows_remove_test.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

VM_TESTS_NORMAL := $(filter-out $(VM_BUILD)/tree-test$(EXE) $(VM_BUILD)/files_private-test$(EXE) $(VM_BUILD)/windows_remove-test$(EXE),$(VM_TESTS))

vm-test: $(VM_TESTS)
	printf '%s\n' $(VM_TESTS_NORMAL) | xargs -P $(JOBS) -n 1 $(VM_TEST_RUNNER)

# TSan over the code that more than one thread touches (docs/vm/10-io-multicore.md §10.2.3, "Order of work"): the inbox, the
# set-once outcome and reference count, the run queue, the wake against the park, and a job on the loop. The VM is built
# without libgc (AGC_NO_GC), so the collector's own signals are out of the picture; the whole run is checked, so a race fails it.
VM_TSAN_TESTS := inbox outcome runq task_wake job
vm-tsan:
	$(MAKE) $(patsubst %,build/vm/tsan/%-test,$(VM_TSAN_TESTS)) TSAN=1 SANITIZE=0 GC_STRESS=0
	printf '%s\n' $(patsubst %,build/vm/tsan/%-test,$(VM_TSAN_TESTS)) | TSAN_OPTIONS=halt_on_error=1 xargs -n 1 $(VM_TEST_RUNNER)

# The C tests as programs, without running them: windows-docker-build builds them in a container.
vm-test-binaries: $(VM_TESTS)

# A local Windows check without a Windows machine. One image (llvm-mingw's UCRT toolchain and Wine,
# tools/windows-check.Dockerfile) builds dist/agentica.exe and the C test programs, and a second container runs them.
# The bootstrap runs the Windows binary it links, because the front end is written in Agentica and compiles itself,
# so the build container needs Wine too. Both containers mount this checkout as the current user, so the objects land
# in build/vm/release/ and a later host build rebuilds them (the flags stamp changes). Docker with BuildKit/buildx,
# the network for the image and about 6 GB of disk are needed.
WINDOWS_IMAGE ?= agentica-windows-check
WINDOWS_DOCKERFILE ?= tools/windows-check.Dockerfile
# The Wine prefix lives in build/, so it is made once (a fresh one costs about a minute) and no root-owned file lands
# in the checkout. The wrappers live there too: the Python tests take the program to run in AGENTICA_TEST_EXECUTABLE
# and AGENTICA_VM_BINARY, one word each, so they cannot carry "wine" themselves.
WINDOWS_WINE_HOME := $(CURDIR)/build/wine-home
WINDOWS_WRAPPER_DIR := build/windows
WINDOWS_CROSS := VM_OS=Windows_NT CC=x86_64-w64-mingw32-gcc AR=llvm-ar RUN_PROGRAM=wine VM_TEST_RUNNER=wine \
  AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored
# The modules the vm-windows job of platforms.yml runs: the bootstrap binary alone, then the product. TESTS= picks
# others (test_cli_forms.py drives only the command line, for instance).
WINDOWS_TEST_MODULES ?= tests/test_single_binary.py tests/test_source_paths.py tests/test_windows_metadata_and_locks.py \
  tests/test_vm_stdout.py tests/test_platform_bootstrap.py
WINDOWS_DOCKER := docker run --rm -v '$(CURDIR):$(CURDIR)' -w '$(CURDIR)' --user "$$(id -u):$$(id -g)" \
  -e HOME=$(WINDOWS_WINE_HOME) -e WINEPREFIX=$(WINDOWS_WINE_HOME)/.wine -e TMPDIR=$(WINDOWS_WINE_HOME)/tmp \
  -e XDG_RUNTIME_DIR=$(WINDOWS_WINE_HOME)/xdg -e WINEDEBUG=-all -e WINEDLLOVERRIDES=mscoree,mshtml=

windows-docker-image:
	@command -v docker >/dev/null || { echo "make windows-docker-* needs docker" >&2; exit 1; }
	@docker buildx version >/dev/null 2>&1 || { echo "make windows-docker-* needs Docker BuildKit with the buildx plugin" >&2; exit 1; }
	DOCKER_BUILDKIT=1 docker build -t $(WINDOWS_IMAGE) -f $(WINDOWS_DOCKERFILE) tools

# The wrappers run a Windows program through Wine. They name Wine by its absolute path, so a test that clears PATH
# (test_platform_bootstrap does) still starts it.
windows-docker-wrappers:
	@mkdir -p $(WINDOWS_WRAPPER_DIR)
	@printf '#!/bin/sh\nexec /usr/bin/wine $(CURDIR)/dist/agentica.exe "$$@"\n' > $(WINDOWS_WRAPPER_DIR)/agentica
	@printf '#!/bin/sh\nexec /usr/bin/wine $(CURDIR)/build/vm/release/bootstrap/agentica.exe "$$@"\n' > $(WINDOWS_WRAPPER_DIR)/bootstrap
	@chmod +x $(WINDOWS_WRAPPER_DIR)/agentica $(WINDOWS_WRAPPER_DIR)/bootstrap

windows-docker-build: windows-docker-image windows-docker-wrappers
	@mkdir -p $(WINDOWS_WINE_HOME)/tmp $(WINDOWS_WINE_HOME)/xdg
	$(WINDOWS_DOCKER) $(WINDOWS_IMAGE) make -j$(JOBS) $(WINDOWS_CROSS) dist/agentica.exe vm-test-binaries

# The vm-windows job of platforms.yml, in its order: the C tests, the bootstrap binary on its own, then the product on
# the Python modules. AGENTICA_VM_BINARY is relative to the repository, as the tests resolve it.
windows-docker-check: windows-docker-build
	$(WINDOWS_DOCKER) $(WINDOWS_IMAGE) sh -c 'set -e; \
	  export AGENTICA_TEST_TARGET_OS=windows AGENTICA_TEST_WINE=1; \
	  export AGENTICA_TEST_EXECUTABLE="$(CURDIR)/$(WINDOWS_WRAPPER_DIR)/agentica"; \
	  export AGENTICA_VM_BINARY="$(WINDOWS_WRAPPER_DIR)/bootstrap"; \
	  $(MAKE) $(WINDOWS_CROSS) vm-test; \
	  python3 -m pytest -p no:cacheprovider tests/test_platform_bootstrap.py; \
	  export AGENTICA_VM_BINARY="$(WINDOWS_WRAPPER_DIR)/agentica"; \
	  $(MAKE) $(WINDOWS_CROSS) test-py TESTS="$(WINDOWS_TEST_MODULES)" PYTHON=python3'

# The Ubuntu test container of `make tests DOCKER=1` and `make tests KIND=files`. It builds the checkout with the
# distribution libgc and OpenSSL (no vendored dependency build), so a cold volume still finishes in a couple of
# minutes. TEST_BASE selects another Ubuntu base; `docker volume ls` lists the cached build volumes.
TEST_IMAGE ?= agentica-ubuntu-test
TEST_BASE ?= ubuntu:26.04
TEST_DOCKERFILE ?= tools/ubuntu-test.Dockerfile

docker-test-image:
	@command -v docker >/dev/null 2>&1 || { echo "make tests DOCKER=1 requires Docker" >&2; exit 1; }
	docker build --build-arg TEST_BASE="$(TEST_BASE)" -t "$(TEST_IMAGE)" -f "$(TEST_DOCKERFILE)" tools

# The Linux removal/rename cases of the destructive group, in the local Docker sandbox (Actions uses its own route).
windows-docker-remove-check:
	$(MAKE) --no-print-directory tests-docker KIND=files

# The Windows removal refusal case under Wine, the optional local compatibility check of KIND=files.
windows-docker-remove-wine-check:
	$(MAKE) --no-print-directory tests-wine KIND=files

# Native destructive regressions run only on ephemeral GitHub Actions runners.
test-remove-actions:
	$(POETRY) run python tools/run_remove_actions.py all

$(VM_BUILD)/agentica-vm-fuzz$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/fuzz_main.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

# The corpus is every fixture compiled by the binary, JOBS at a time
FUZZ_CORPUS = printf '%s\n' tests/fixtures/vm/*.agc | xargs -P $(JOBS) -I{} sh -c \
  'dist/agentica$(EXE) compile "$$1" -o "$(VM_BUILD)/corpus/$$(basename "$$1" .agc).agcb"' sh {}

# The fuzzer links the VM objects and no front end: it is an internal artifact of build/, never shipped.
vm-fuzz: dist/agentica$(EXE) $(VM_BUILD)/agentica-vm-fuzz$(EXE)
	@mkdir -p $(VM_BUILD)/corpus
	$(FUZZ_CORPUS)
	$(VM_BUILD)/agentica-vm-fuzz $(FUZZ_RUNS) $(VM_BUILD)/corpus/*.agcb

# The golden tests compile with dist/agentica and run on the GC stress binary (AGENTICA_VM_BINARY): the front end does not
# run under the stress. The binary links the stage2 that dist/agentica was built from.
vm-gc-stress: dist/agentica$(EXE)
	$(MAKE) build/vm/gcstress/agentica$(EXE) vm-test GC_STRESS=1 SANITIZE=0
	AGENTICA_VM_BINARY=build/vm/gcstress/agentica$(EXE) AGENTICA_REQUIRE_VM=1 AGENTICA_SWEEP=$${AGENTICA_SWEEP:-sampled} \
	  $(MAKE) --no-print-directory test-py TESTS="$(VM_DIFF_TESTS)"

# Build the VM and its C tests with the trace points compiled out, and check that --version says so
vm-trace-off:
	$(MAKE) -j$(JOBS) dist/agentica$(EXE) vm-test TRACE=0
	dist/agentica$(EXE) run --version | grep -q 'trace off'

# The golden tests (tests/test_vm_diff_*.py) compile with dist/agentica and run on it too (`agentica run`;
# AGENTICA_VM_BINARY names another binary to run on).
vm-diff-build: dist/agentica$(EXE)

# vm-diff-test and vm-sanitize-* do not depend on dist/agentica on purpose: they test the binary that an earlier step built.
vm-diff-test:
	@$(MAKE) --no-print-directory test-py TESTS="$(VM_DIFF_TESTS)"

# The golden tests with the full --max-steps sweep (weekly in CI)
sweep-full: vm-diff-build
	AGENTICA_REQUIRE_VM=1 AGENTICA_SWEEP=full $(MAKE) --no-print-directory test-py TESTS="$(VM_DIFF_TESTS)"

# The test modules that run against the built binary (make test-py runs them; the ASan job runs them on the sanitizer
# binary). They need dist/agentica, which make builds first; without it a module skips locally and fails in CI.
VM_PY_TESTS = $(VM_DIFF_TESTS) tests/test_vm_stack.py tests/test_single_binary.py tests/test_vm_stop.py tests/test_vm_stdout.py tests/test_vm_file_lines.py tests/test_vm_os.py tests/test_vm_tcp.py tests/test_vm_tls.py tests/test_vm_http.py tests/test_vm_test_protocol.py tests/test_vm_child_channel.py tests/test_vm_channel.py tests/test_vm_trace.py
SANITIZE_JOBS ?= 4

vm-sanitize-build: dist/agentica$(EXE)

vm-sanitize-test: vm-sanitize-build
	@$(MAKE) --no-print-directory test-py TESTS="$(VM_PY_TESTS)" JOBS=$(SANITIZE_JOBS)

# Link the VM against the vendored OpenSSL and libgc and check that it is static and the version is the submodule's
vendored-check:
	$(MAKE) -j$(JOBS) build/vm/release/agentica AGENTICA_OPENSSL=vendored AGENTICA_GC=vendored
	@if readelf -d build/vm/release/agentica | grep -qE 'NEEDED.*lib(ssl|crypto|gc)[.]'; then echo "the vendored binary links OpenSSL or libgc dynamically" >&2; exit 1; fi
	@ossl=$$(awk -F= '/^(MAJOR|MINOR|PATCH)=/ { printf "%s%s", sep, $$2; sep = "." }' vm/third_party/openssl/VERSION.dat); \
	  build/vm/release/agentica run --version | grep -qF "OpenSSL $$ossl" || { echo "the vendored binary does not report OpenSSL $$ossl" >&2; exit 1; }

# vendored-check, then the TLS and HTTP tests on that binary
vendored-test: vendored-check
	AGENTICA_VM_BINARY=build/vm/release/agentica $(MAKE) --no-print-directory test-py JOBS=2 TESTS="tests/test_vm_tls.py tests/test_vm_http.py"

CLANG_TIDY ?= clang-tidy
# vm/unicode_data.c is frozen table data (see its header), so it is not linted
VM_LINT_SKIP := vm/unicode_data.c
VM_LINT_SRC := $(filter-out $(VM_LINT_SKIP),$(wildcard vm/*.c vm/tests/*.c))

.PHONY: vm-lint vm-lint-check vm-lint-release vm-lint-sanitize vm-lint-gcstress
vm-lint: vm-lint-release vm-lint-sanitize vm-lint-gcstress

vm-lint-check: $(OSSL_DEP) $(GC_DIR)/extra/gc.c $(YY_DIR)/src/yyjson.c $(PICO_DIR)/picohttpparser.c $(UV_DIR)/src/uv-common.c
	@$(CLANG_TIDY) --version
	@major=$$($(CLANG_TIDY) --version | sed -n 's/.*version \([0-9][0-9]*\).*/\1/p' | head -n 1); \
	  if [ -z "$$major" ] || [ "$$major" -lt 19 ]; then echo "clang-tidy $${major:-unknown} is too old: misc-use-internal-linkage needs clang-tidy 19 or newer" >&2; exit 1; fi
	@$(CLANG_TIDY) --list-checks -checks=misc-use-internal-linkage | grep -q misc-use-internal-linkage || { echo "clang-tidy 19+ required" >&2; exit 1; }

vm-lint-release vm-lint-sanitize vm-lint-gcstress: vm-lint-check

LINT = printf '%s\n' $(VM_LINT_SRC) | xargs -P $(JOBS) -I{} $(CLANG_TIDY) --quiet {} -- $(VM_WARN) $(OSSL_INC)

vm-lint-release:
	$(LINT) -I $(GC_DIR)/include

vm-lint-sanitize:
	$(LINT) -DAGC_NO_GC -fsanitize=address,undefined

vm-lint-gcstress:
	$(LINT) -I $(GC_DIR)/include -DGC_DEBUG -DAGC_GC_STRESS

vm-layers: $(VM_OBJS) $(VM_OBJ)/agentica.o $(VM_OBJ)/launch.o
	for h in vm/*.h; do $(VM_CC) $(VM_CFLAGS) -fsyntax-only -x c -include $$h /dev/null || exit 1; done
	sh vm/tools/check-layers.sh $(VM_OBJ)
	sh vm/tools/check-layers-test.sh $(VM_OBJ) $(VM_CC) $(VM_CFLAGS)
