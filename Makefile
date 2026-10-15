RACO ?= raco
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
TESTS ?= tests/
unexport AGENTICA_VM_TRACE AGENTICA_VM_TRACE_FILE AGENTICA_FLUSH_TIMEOUT_MS
VM_DIFF_TESTS = $(sort $(wildcard tests/vm-diff-*-test.rkt))
EXE_INPUTS := $(wildcard src/*.rkt stdlib/MODULES stdlib/*.agc stdlib/*/*.agc)
BDD_DRIVER_INPUTS := $(wildcard compiler/*.agc src/*.rkt)
# The single binary (docs/future/35-self-hosting.md, 35.6) is built beside dist/agentica-vm; Linux only for now. The tests
# that need it (the whole suite, or tests/test_single_binary.py) build it first.
ifeq ($(shell uname -s),Linux)
AGC_NEXT := dist/agentica-next
endif
NEXT_TESTS := tests tests/test_single_binary.py

.PHONY: build build-tests bdd-driver test test-slow test-rkt test-py test-exe test-ci test-distribution exe clean test-bdd smoke goldens bench eval-references version vm vm-test vm-latency vm-fuzz stage1 stage2 stage3 fixed-point agentica-next vm-gc-stress vm-trace-off vm-layers vm-diff-build vm-diff-test vm-golden-check sweep-full vm-sanitize-build vm-sanitize-test vendored-check vendored-test vm-unicode vm-unicode-check vm-openssl vm-openssl-key vm-third-party vm-third-party-key site site-serve site-sass dup-check dup-baseline FORCE

version:
	@racket -e '(require "src/version.rkt") (display version)'

build:
	$(RACO) make src/main.rkt

# Two frameworks side by side while the tests move from rackunit to Python unittest (docs/future/35-self-hosting.md
# section 35.10, references/ci.md): a .rkt file in TESTS goes to raco test, a tests/test_<area>.py file to unittest, and a
# directory (the default, tests/) to both. A test lives in one framework only.
# All tests, in parallel:      make test
# A subset:                    make test TESTS="tests/lexer-test.rkt tests/parser-test.rkt tests/test_vm_bits.py"
# More or fewer workers:       make test JOBS=8
PYTHON ?= python3
RKT_TESTS = $(filter-out %.py,$(TESTS))
# TESTS without a leading ./ or a trailing /. A directory contributes its own test_*.py files, not those of subdirectories
# (tests/eval/test_*.py are not unittest modules for this runner).
TESTS_NORM = $(patsubst %/,%,$(patsubst ./%,%,$(TESTS)))
PY_FILES = $(filter %.py,$(TESTS_NORM))
# Modules that only run when named (make vm-latency): a directory in TESTS does not pick them up
PY_ALONE = tests/test_vm_latency.py
NEXT_PREREQ = $(if $(filter $(NEXT_TESTS),$(TESTS_NORM)),$(AGC_NEXT))
PY_TESTS = $(sort $(PY_FILES) $(filter-out $(PY_ALONE),$(foreach t,$(filter-out %.py,$(TESTS_NORM)),$(wildcard $(t)/test_*.py))))
# A .py path outside tests/test_<area>.py would build a wrong module name below
PY_BAD = $(filter-out tests/test_%.py,$(PY_FILES)) $(foreach f,$(filter tests/test_%.py,$(PY_FILES)),$(if $(findstring /,$(f:tests/%=%)),$(f)))
PY_CHECK = $(if $(strip $(PY_BAD)),$(error TESTS: $(strip $(PY_BAD)) is not a tests/test_<area>.py file))
# tests/test_x.py -> tests.test_x (run from the repository root, so tests/agentica_test.py imports as tests.agentica_test)
PY_MODULE = $(subst /,.,$(patsubst %.py,%,$(1)))
RKT_FLAGS ?=

# -k: the unittest run still happens when the rackunit run fails, so one run shows every failure.
# AGENTICA_TEST_SLOW= keeps a stray flag in the environment from turning this into a slow run.
test: build vm bdd-driver $(NEXT_PREREQ)
	@: $(PY_CHECK)
	@$(MAKE) --no-print-directory -k test-rkt test-py AGENTICA_TEST_SLOW=

# The slow tier: the (module+ slow ...) cases of the .rkt files and the @slow cases of the .py files
# (tests/agentica_test.py, AGENTICA_TEST_SLOW=1). CI runs it after make test; a local run does not.
# A .rkt file without a slow submodule is skipped; with the flag a .py file runs only its @slow cases.
test-slow: build vm bdd-driver $(NEXT_PREREQ)
	@: $(PY_CHECK)
	@$(MAKE) --no-print-directory -k test-rkt test-py RKT_FLAGS="--submodule slow --no-run-if-absent" AGENTICA_TEST_SLOW=1

test-rkt:
	@test -z "$(RKT_TESTS)" || $(RACO) test $(RKT_FLAGS) -j $(JOBS) $(RKT_TESTS)

# One unittest process per module, run by make itself: -j gives the workers, -O (GNU make 4.0 or newer) keeps each
# module's output together, -k runs the other modules after a failure. A failing module shows its unittest report and a make error line.
# CI (CI is set) fails when Python is missing; a local run reports a skip, like the Racket tests do for their peers.
test-py:
	@: $(PY_CHECK)
	@if [ -n "$(PY_TESTS)" ]; then \
	  if ! command -v $(PYTHON) >/dev/null 2>&1; then \
	    test -z "$$CI" || { echo "$(PYTHON) is required in CI" >&2; exit 1; }; \
	    echo "SKIP the Python tests: $(PYTHON) is unavailable"; exit 0; \
	  fi; \
	  $(MAKE) --no-print-directory -k -O -j$(JOBS) $(addprefix py-test/,$(PY_TESTS)) \
	    || { echo "The Python tests failed" >&2; exit 1; }; \
	fi

py-test/%: FORCE
	@echo "unittest $*"
	@$(PYTHON) -m unittest $(call PY_MODULE,$*)

# The BDD driver of `agentica test` (compiler/bdd.agc), compiled once here by the Racket front end and run by the VM; it
# sits next to the VM and the executable (docs/future/35-self-hosting.md, step 7b). Racket compiles `compiler/` to the
# same bytes every time, so the file only changes with its inputs.
dist/agentica-bdd-driver.agcb: $(BDD_DRIVER_INPUTS) | build
	mkdir -p dist
	racket src/main.rkt compile compiler/bdd.agc -o $@

bdd-driver: dist/agentica-bdd-driver.agcb

dist/agentica: $(EXE_INPUTS) | build vm bdd-driver
	mkdir -p dist
	$(RACO) exe -o dist/agentica src/main.rkt

exe: dist/agentica

# Speed check (docs/vm-benchmarks.md): make bench BENCH_ARGS="--runs 3 --size 2"
# dist/agentica is timed only when present; rebuild it with make exe first, or pass --runners vm,python
bench: build vm
	python3 benchmarks/run.py $(BENCH_ARGS)

eval-references:
	python3 tests/eval/run.py --check-references --jobs 8

# Task wake latency next to busy tasks (docs/vm/10-io-scheduler.md 10.2.1), alone so it has the CPU to itself
vm-latency: build vm
	@$(MAKE) --no-print-directory test-py TESTS=tests/test_vm_latency.py

test-bdd: exe
	dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc

# Example smoke runs on racket src/main.rkt and dist/agentica, in parallel (tests/smoke.sh).
# dist/agentica is rebuilt when a file in src/ or stdlib/ is newer than it.
smoke: build vm dist/agentica
	tests/smoke.sh

# ci.yml, sweep.yml and the release tests run their checks as the targets below, so the same command works locally.

# Compile every Racket test module
build-tests: build
	$(RACO) make -j $(JOBS) tests/*.rkt

# The process and module tests on the built executable (tests/test-ci.sh exe)
test-exe: build vm dist/agentica
	tests/test-ci.sh exe

# make test with JOBS=6 and test-exe running beside it (tests/test-ci.sh)
test-ci: build vm dist/agentica
	+MAKE='$(MAKE)' tests/test-ci.sh

# The distributed executable still finds its std/ modules after its build checkout is gone
test-distribution: build vm
	$(RACO) test tests/stdlib-distribution-test.rkt

# make goldens FIXTURES="name ..." rewrites only those fixtures (names without .agc)
# Without FIXTURES it also rewrites the front-end goldens of tests/fixtures/frontend/ from the Racket stages
goldens: build vm
	AGENTICA_FIXTURES="$(FIXTURES)" racket tests/vm-diff-common.rkt
	AGENTICA_FIXTURES="$(FIXTURES)" racket tests/vm-stack-test.rkt
	test -n "$(FIXTURES)" || racket tests/frontend-lexer-common.rkt
	test -n "$(FIXTURES)" || racket tests/frontend-parser-common.rkt
	test -n "$(FIXTURES)" || racket tests/frontend-modules-common.rkt
	test -n "$(FIXTURES)" || racket tests/frontend-catalog-common.rkt
	test -n "$(FIXTURES)" || racket tests/frontend-check-common.rkt

# make vm-golden-check FIXTURES="name ..." runs the golden check of CI on only those fixtures
vm-golden-check: build vm
	AGENTICA_FIXTURES="$(FIXTURES)" racket tests/vm-diff-common.rkt check
	AGENTICA_FIXTURES="$(FIXTURES)" $(RACO) test tests/vm-stack-test.rkt

JSCPD ?= tools/jscpd/node_modules/.bin/jscpd

tools/jscpd/node_modules: tools/jscpd/package.json tools/jscpd/package-lock.json
	npm ci --prefix tools/jscpd --ignore-scripts --no-audit --no-fund
	touch $@

dup-check: tools/jscpd/node_modules
	$(JSCPD) --baseline .jscpd-baseline.json --fail-on-new-clones

dup-baseline: tools/jscpd/node_modules
	$(JSCPD) --baseline .jscpd-baseline.json --update-baseline --reporters silent

clean:
	find . -name compiled -type d -prune -exec rm -rf {} +
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
# make vm                 dist/agentica-vm
# make vm-test            C tests in vm/tests/, run in parallel
# make vm SANITIZE=1      clang with ASan and UBSan, no libgc
# Each mode compiles vm/*.c once into build/vm/<mode>/obj/ (-MMD header dependencies) and links every binary from it.
# Compiles go through ccache when it is installed and its cache directory is writable (CCACHE= turns it off); CCACHE_BASEDIR is
# the checkout and the -g modes map it to . in debug info (-fdebug-prefix-map), so worktrees share hits.
# make vm TRACE=0         compile out the AGENTICA_VM_TRACE trace points
# make vm-fuzz            mutate compiled fixtures and run them
# make vm-gc-stress       GC-debug build that collects every 64 allocations, on the differential tests (sampled --max-steps sweep)
# make vm-unicode         regenerate vm/unicode_data.c from Racket
# make vm-lint            clang-tidy (19 or newer) over vm/*.c and vm/tests/*.c in the release, sanitizer and GC-stress configurations, files in parallel
# make vm-layers          the layer check of docs/vm/15-layers.md: each header compiles alone, the include and link rules hold, planted violations fail (Linux only)
# make vm AGENTICA_GC=vendored  build libgc from vm/third_party/bdwgc into build/vm/gc.o and link it statically (the release, the GC-stress build and
#                         non-Linux hosts do); pass it to every make command or export it. The Linux default AGENTICA_GC=system links the system
#                         libgc 8.2 or newer found by pkg-config (Debian: libgc-dev pkg-config) and checks it before any vm/*.c compile.
# make vm AGENTICA_OPENSSL=vendored  build OpenSSL from vm/third_party/openssl and link it statically (the release does); pass it to
#                         every make command or export it. The default AGENTICA_OPENSSL=system links the system OpenSSL 3 found by pkg-config
#                         (Debian: libssl-dev pkg-config) and checks it before any vm/*.c compile.
# make vm-openssl         AGENTICA_OPENSSL=vendored: build only the static libraries; AGENTICA_OPENSSL=system: check the system OpenSSL
# make vm-openssl-key     AGENTICA_OPENSSL=vendored only: print what the OpenSSL build of this mode depends on (the CI cache key)
# make vm-third-party     build (AGENTICA_GC=vendored) or check (system) libgc, and build yyjson, picohttpparser and libuv for this mode (no libgc with SANITIZE=1, no libuv off Linux)
# make vm-third-party-key print what those builds depend on (the CI cache key); they rebuild only when it changes
AGC_VERSION := $(shell sed -n 's/^(define version "\(.*\)")$$/\1/p' src/version.rkt)
GC_DIR := vm/third_party/bdwgc
YY_DIR := vm/third_party/yyjson
PICO_DIR := vm/third_party/picohttpparser
UV_DIR := vm/third_party/libuv
OSSL_DIR := vm/third_party/openssl
YY_DEFS := -DYYJSON_DISABLE_WRITER=1 -DYYJSON_DISABLE_INCR_READER=1 -DYYJSON_DISABLE_FILE=1 -DYYJSON_DISABLE_UTILS=1 -DYYJSON_DISABLE_NON_STANDARD=1 -DYYJSON_DISABLE_FAST_FP_CONV=1
VM_SRC := vm/value.c vm/text.c vm/map.c vm/list.c vm/unicode_data.c vm/loader.c vm/builtins.c vm/builtin_tables.c vm/strings.c vm/numbers.c vm/random.c vm/input.c vm/output.c vm/json.c vm/json_value.c vm/json_typed.c vm/loop.c vm/files.c vm/tree.c vm/stream.c vm/duplex.c vm/process.c vm/tcp.c vm/tls_openssl.c vm/http_pico.c vm/http_body.c vm/http_fields.c vm/http_client.c vm/http_server.c vm/logger.c vm/front_end.c vm/interp.c vm/task.c vm/channel.c vm/equal.c vm/testing.c vm/diag.c vm/trace.c
EXE :=
VM_PIC := -fPIE
VM_PIE := -pie
VM_HARDEN_LDFLAGS := $(VM_PIE) -Wl,-z,relro,-z,now
VM_LIBS := -lpthread -lm
VM_ENTRY :=
ifeq ($(OS),Windows_NT)
ifeq ($(origin CC),default)
CC := gcc
endif
EXE := .exe
VM_PIC :=
VM_PIE :=
VM_HARDEN_LDFLAGS := -Wl,--dynamicbase,--nxcompat,--high-entropy-va
VM_LIBS :=
VM_ENTRY := -municode
else ifeq ($(shell uname -s),Darwin)
VM_PIE :=
VM_HARDEN_LDFLAGS :=
endif
UV_NAMES :=
AGENTICA_GC_DEFAULT := vendored
ifeq ($(shell uname -s),Linux)
AGENTICA_GC_DEFAULT := system
UV_NAMES := fs-poll idna inet random strscpy strtok thread-common threadpool timer uv-common uv-data-getter-setters version \
  unix/async unix/core unix/dl unix/fs unix/getaddrinfo unix/getnameinfo unix/loop-watcher unix/loop unix/pipe unix/poll \
  unix/process unix/random-devurandom unix/signal unix/stream unix/tcp unix/thread unix/tty unix/udp \
  unix/linux unix/procfs-exepath unix/random-getrandom unix/random-sysctl-linux unix/proctitle
VM_LIBS += -ldl -lrt
endif
AGENTICA_GC ?= $(AGENTICA_GC_DEFAULT)
PKG_CONFIG ?= pkg-config
GC_MIN := 8.2.0
ifeq ($(filter $(AGENTICA_GC),system vendored),)
$(error AGENTICA_GC must be system or vendored, not '$(AGENTICA_GC)')
endif
UV_DEFS := -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112
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
GC_COMPILE = $(CC) -std=c11 -O2 $(VM_PIC) -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION -I $(GC_DIR)/include
YY_COMPILE = $(VM_CC) -std=c11 $(YY_CFLAGS) $(YY_DEFS)
PICO_COMPILE = $(VM_CC) -std=c11 $(YY_CFLAGS)
UV_COMPILE = $(VM_CC) -std=gnu11 $(YY_CFLAGS) $(UV_DEFS) -I $(UV_DIR)/include -I $(UV_DIR)/src
SUBMODULE_KEY = if [ "$$(git -C $(1) rev-parse --show-toplevel 2>/dev/null)" = '$(CURDIR)/$(1)' ]; then \
  git ls-tree HEAD $(1); git -C $(1) rev-parse HEAD; git -C $(1) diff --no-ext-diff --no-color --binary HEAD | cksum; \
  (cd $(1) && git ls-files -z -o --exclude-standard | xargs -0r cksum); \
  else echo 'no git checkout: $(1)'; find $(1) -type f ! -path '*/.git/*' -print0 | LC_ALL=C sort -z | xargs -0r cksum | cksum; fi
GC_SYSTEM_KEY = { $(PKG_CONFIG) --modversion bdw-gc 2>/dev/null; echo '$(GC_INC) $(GC_LINK)'; }
GC_KEY = { echo '$(GC_COMPILE)'; $(CC) --version 2>/dev/null | head -n 1; $(call SUBMODULE_KEY,$(GC_DIR)); }
TP_KEY = { echo '$(YY_COMPILE) | $(PICO_COMPILE) | $(UV_COMPILE) | $(UV_NAMES) | $(AR) rcs'; $(VM_CC) --version 2>/dev/null | head -n 1; \
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
OSSL_ENV := env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOVERRIDES -u CC -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS -u LDLIBS
OSSL_LAUNCH = $(CCACHE)
OSSL_CONFIGURE = $(OSSL_ENV) CC='$(strip $(OSSL_LAUNCH) $(VM_CC))' perl $(CURDIR)/$(OSSL_DIR)/Configure $(OSSL_OPTS) $(OSSL_CFLAGS)
OSSL_SUBMAKE = $(OSSL_ENV) make -C $(OSSL_BUILD) CC='$(strip $(OSSL_LAUNCH) $(VM_CC))' build_libs
OSSL_RECIPE = $(subst ','\'',$(subst $(CURDIR)/,,$(OSSL_CONFIGURE) | $(OSSL_SUBMAKE)))
OSSL_KEY = { echo '$(OSSL_RECIPE)'; $(VM_CC) --version 2>/dev/null | head -n 1; cat $(OSSL_DIR)/VERSION.dat; \
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

dist/agentica-vm$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/main.o $(VM_OBJ)/launch.o $(VM_LINK_LIBS) $(VM_STAMP)
	@mkdir -p dist
	$(VM_LINK) $(VM_ENTRY)

vm: dist/agentica-vm$(EXE)

# The single binary and its bootstrap (docs/future/35-self-hosting.md, 35.3 and 35.6; docs/vm/08-loader-and-cli.md).
# The front end is compiler/front_end.agc. Each stage is the .agcb of the front end, in build/stage/:
#   stage1  compiled by the Racket compiler (src/)
#   stage2  compiled by stage1, run on dist/agentica-vm with the std/ sources from stdlib/
#   stage3  compiled by stage2 in the same way
# The fixed point is stage2 == stage3, byte for byte, and stage1 == stage2 (Racket and the Agentica compiler agree, while
# Racket exists). stage2 is the front end that dist/agentica-next carries; the binary then compiles it once more with its
# embedded std/ sources, and that must be stage2 as well.
# make fixed-point        build the stages and the binary, and check all of the above
# make agentica-next      dist/agentica-next only (it needs stage1 and stage2)
STAGE_DIR := build/stage
FRONT_END_SRC := compiler/front_end.agc
STD_NAMES := $(shell cat stdlib/MODULES)
STD_FILES := $(addprefix stdlib/,$(STD_NAMES))
STAGE_INPUTS := $(wildcard compiler/*.agc) stdlib/MODULES $(STD_FILES)
# The VM runs a stage as: PROGRAM --version V --stdlib DIR -- WORDS (compiler/front_end_inputs.agc)
STAGE_RUN = dist/agentica-vm$(EXE) -- $< --version $(AGC_VERSION) --stdlib stdlib -- compile $(FRONT_END_SRC) -o $@

$(STAGE_DIR)/stage1.agcb: $(STAGE_INPUTS) $(wildcard src/*.rkt) | build
	@mkdir -p $(STAGE_DIR)
	racket src/main.rkt compile $(FRONT_END_SRC) -o $@

$(STAGE_DIR)/stage2.agcb: $(STAGE_DIR)/stage1.agcb $(STAGE_INPUTS) dist/agentica-vm$(EXE)
	$(STAGE_RUN)

$(STAGE_DIR)/stage3.agcb: $(STAGE_DIR)/stage2.agcb $(STAGE_INPUTS) dist/agentica-vm$(EXE)
	$(STAGE_RUN)

stage1: $(STAGE_DIR)/stage1.agcb
stage2: $(STAGE_DIR)/stage2.agcb
stage3: $(STAGE_DIR)/stage3.agcb

# The std/ sources and the front end go into the binary through a generated assembly file with .incbin (not through ccache,
# which cannot see the files that .incbin reads). Linux and ELF only.
$(VM_BUILD)/embedded.s: vm/tools/gen-embedded.sh stdlib/MODULES $(STAGE_DIR)/stage2.agcb $(STD_FILES)
	@mkdir -p $(VM_BUILD)
	sh vm/tools/gen-embedded.sh $(STAGE_DIR)/stage2.agcb stdlib stdlib/MODULES > $@

$(VM_OBJ)/embedded.o: $(VM_BUILD)/embedded.s $(VM_OBJ_STAMP) $(STAGE_DIR)/stage2.agcb $(STD_FILES)
	@mkdir -p $(VM_OBJ)
	$(VM_CC) -x assembler -c $< -o $@

dist/agentica-next: $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/agentica.o $(VM_OBJ)/launch.o $(VM_OBJ)/embedded.o $(VM_LINK_LIBS) $(VM_STAMP)
	@mkdir -p dist
	$(VM_LINK)

agentica-next: dist/agentica-next

fixed-point: $(STAGE_DIR)/stage1.agcb $(STAGE_DIR)/stage2.agcb $(STAGE_DIR)/stage3.agcb dist/agentica-next
	cmp $(STAGE_DIR)/stage2.agcb $(STAGE_DIR)/stage3.agcb || { echo "fixed point: stage2 and stage3 differ" >&2; exit 1; }
	cmp $(STAGE_DIR)/stage1.agcb $(STAGE_DIR)/stage2.agcb || { echo "fixed point: Racket's stage1 and stage2 differ" >&2; exit 1; }
	dist/agentica-next compile $(FRONT_END_SRC) -o $(STAGE_DIR)/stage4.agcb
	cmp $(STAGE_DIR)/stage2.agcb $(STAGE_DIR)/stage4.agcb || { echo "fixed point: dist/agentica-next compiles another front end" >&2; exit 1; }

VM_TESTS := $(patsubst vm/tests/%_test.c,$(VM_BUILD)/%-test$(EXE),$(wildcard vm/tests/*_test.c))
.SECONDARY: $(patsubst vm/tests/%.c,$(VM_OBJ)/tests/%.o,$(wildcard vm/tests/*_test.c))

$(VM_BUILD)/%-test$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/tests/%_test.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

vm-test: $(VM_TESTS)
	printf '%s\n' $(VM_TESTS) | xargs -P $(JOBS) -n 1 env

$(VM_BUILD)/agentica-vm-fuzz$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/fuzz_main.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

FUZZ_CORPUS = racket -e '(require (file "tests/vm-diff-common.rkt") racket/path)' \
  -e '(for ([f (current-command-line-arguments)]) (compile-file (string->path f) (build-path "$(VM_BUILD)/corpus" (path-replace-extension (file-name-from-path f) \#".agcb"))))'

vm-fuzz: build $(VM_BUILD)/agentica-vm-fuzz$(EXE)
	@mkdir -p $(VM_BUILD)/corpus
	$(RACO) make tests/vm-diff-common.rkt
	$(FUZZ_CORPUS) tests/fixtures/vm/*.agc
	$(VM_BUILD)/agentica-vm-fuzz $(FUZZ_RUNS) $(VM_BUILD)/corpus/*.agcb

$(VM_BUILD)/agentica-vm$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/main.o $(VM_OBJ)/launch.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK) $(VM_ENTRY)

vm-gc-stress: build
	$(MAKE) build/vm/gcstress/agentica-vm$(EXE) vm-test GC_STRESS=1 SANITIZE=0
	AGENTICA_VM_BINARY=build/vm/gcstress/agentica-vm$(EXE) AGENTICA_REQUIRE_VM=1 AGENTICA_SWEEP=$${AGENTICA_SWEEP:-sampled} \
	  $(RACO) test -j $(JOBS) $(VM_DIFF_TESTS)

# Build the VM and its C tests with the trace points compiled out, and check that --version says so
vm-trace-off:
	$(MAKE) -j$(JOBS) vm vm-test TRACE=0
	dist/agentica-vm$(EXE) --version | grep -q 'trace off'

# The golden tests (tests/vm-diff-*-test.rkt): compile them, then run them on the VM that is built
# (AGENTICA_VM_BINARY names another one)
vm-diff-build: build vm
	$(RACO) make -j $(JOBS) $(VM_DIFF_TESTS)

# vm-diff-test and vm-sanitize-* do not depend on vm on purpose: they test the VM that an earlier step built.
vm-diff-test: build
	$(RACO) test -j $(JOBS) $(VM_DIFF_TESTS)

# The golden tests with the full --max-steps sweep (weekly in CI)
sweep-full: vm-diff-build
	AGENTICA_REQUIRE_VM=1 AGENTICA_SWEEP=full $(RACO) test -j $(JOBS) $(VM_DIFF_TESTS)

# The Racket tests that run against the built VM (the ASan job runs them on the sanitizer VM)
VM_RKT_TESTS = $(VM_DIFF_TESTS) tests/bytecode-test.rkt tests/vm-stack-test.rkt
# The unittest modules that do the same (make test-py runs them)
VM_PY_TESTS = tests/test_vm_stop.py tests/test_vm_stdout.py tests/test_vm_file_lines.py tests/test_vm_os.py tests/test_vm_tcp.py tests/test_vm_tls.py tests/test_vm_http.py tests/test_vm_test_protocol.py tests/test_vm_child_channel.py tests/test_vm_channel.py tests/test_vm_trace.py
SANITIZE_JOBS ?= 4

vm-sanitize-build: build
	$(RACO) make -j $(JOBS) $(VM_RKT_TESTS)

# Both runs happen, so one job shows the failures of both frameworks
vm-sanitize-test: vm-sanitize-build
	@status=0; \
	  $(RACO) test -j $(SANITIZE_JOBS) $(VM_RKT_TESTS) || status=1; \
	  $(MAKE) --no-print-directory test-py TESTS="$(VM_PY_TESTS)" JOBS=$(SANITIZE_JOBS) || status=1; \
	  exit $$status

# Link the VM against the vendored OpenSSL and libgc and check that it is static and the version is the submodule's
vendored-check:
	$(MAKE) -j$(JOBS) build/vm/release/agentica-vm AGENTICA_OPENSSL=vendored AGENTICA_GC=vendored
	@if readelf -d build/vm/release/agentica-vm | grep -qE 'NEEDED.*lib(ssl|crypto|gc)[.]'; then echo "the vendored VM links OpenSSL or libgc dynamically" >&2; exit 1; fi
	@ossl=$$(awk -F= '/^(MAJOR|MINOR|PATCH)=/ { printf "%s%s", sep, $$2; sep = "." }' vm/third_party/openssl/VERSION.dat); \
	  build/vm/release/agentica-vm --version | grep -qF "OpenSSL $$ossl" || { echo "the vendored VM does not report OpenSSL $$ossl" >&2; exit 1; }

# vendored-check, then the TLS and HTTP tests on that binary
vendored-test: vendored-check build
	AGENTICA_VM_BINARY=build/vm/release/agentica-vm $(MAKE) --no-print-directory test-py JOBS=2 TESTS="tests/test_vm_tls.py tests/test_vm_http.py"

vm-unicode:
	racket vm/tools/gen-unicode.rkt vm/unicode_data.c

# vm-unicode, then fail when vm/unicode_data.c changed; build/unicode-checked is CI's cache marker
vm-unicode-check: vm-unicode
	git diff --exit-code vm/unicode_data.c
	mkdir -p build
	touch build/unicode-checked

CLANG_TIDY ?= clang-tidy
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

vm-layers: vm
	for h in vm/*.h; do $(VM_CC) $(VM_CFLAGS) -fsyntax-only -x c -include $$h /dev/null || exit 1; done
	sh vm/tools/check-layers.sh $(VM_OBJ)
	sh vm/tools/check-layers-test.sh $(VM_OBJ) $(VM_CC) $(VM_CFLAGS)
