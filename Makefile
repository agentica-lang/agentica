RACO ?= raco
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
TESTS ?= tests/
unexport AGENTICA_VM_TRACE AGENTICA_VM_TRACE_FILE
VM_DIFF_TESTS = tests/vm-diff-1-test.rkt tests/vm-diff-2-test.rkt tests/vm-diff-3-test.rkt tests/vm-diff-4-test.rkt

.PHONY: build test exe clean test-bdd goldens bench version vm vm-test vm-latency vm-fuzz vm-gc-stress vm-unicode vm-openssl vm-openssl-key vm-third-party vm-third-party-key site site-serve site-sass dup-check dup-baseline FORCE

version:
	@racket -e '(require "src/version.rkt") (display version)'

build:
	$(RACO) make src/main.rkt

# All tests, in parallel:      make test
# A subset:                    make test TESTS="tests/lexer-test.rkt tests/parser-test.rkt"
# More or fewer workers:       make test JOBS=8
test: build vm
	$(RACO) test -j $(JOBS) $(TESTS)

exe: build vm
	mkdir -p dist
	$(RACO) exe -o dist/agentica src/main.rkt

# Speed check (docs/vm-benchmarks.md): make bench BENCH_ARGS="--runs 3 --size 2"
# dist/agentica is timed only when present; rebuild it with make exe first, or pass --runners vm,python
bench: build vm
	python3 benchmarks/run.py $(BENCH_ARGS)

# Task wake latency next to busy tasks (docs/vm/10-io-scheduler.md 10.2.1), alone so it has the CPU to itself
vm-latency: build vm
	$(RACO) test tests/vm-latency-test.rkt

test-bdd: exe
	dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc

goldens: build vm
	racket tests/vm-diff-common.rkt

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

site-sass:
	@command -v sass >/dev/null || { echo "The site needs Dart Sass: put its sass on PATH or in $(DART_SASS) (pinned version in .github/workflows/pages.yml)" >&2; exit 1; }

site: site-sass
	hugo --cleanDestinationDir --source site --panicOnWarning $(HUGO_FLAGS)

site-serve: site-sass
	hugo server --source site

# The C VM (docs/vm/11-build-ci-supply-chain.md section 11). libgc is built from the pinned submodule.
# make vm                 dist/agentica-vm
# make vm-test            C tests in vm/tests/
# make vm SANITIZE=1      clang with ASan and UBSan, no libgc
# make vm TRACE=0         compile out the AGENTICA_VM_TRACE trace points
# make vm-fuzz            mutate compiled fixtures and run them
# make vm-gc-stress       GC-debug build that collects every 64 allocations, on the differential tests
# make vm-unicode         regenerate vm/unicode_data.c from Racket
# make vm-lint            clang-tidy (19 or newer) over vm/*.c and vm/tests/*.c in the release, sanitizer and GC-stress configurations
# make vm VM_OPENSSL=vendored  build OpenSSL from vm/third_party/openssl and link it statically (the release does); pass it to
#                         every make command or export it. The default VM_OPENSSL=system links the system OpenSSL 3 found by pkg-config
#                         (Debian: libssl-dev pkg-config) and checks it before building anything else.
# make vm-openssl         VM_OPENSSL=vendored: build only the static libraries; VM_OPENSSL=system: check the system OpenSSL
# make vm-openssl-key     VM_OPENSSL=vendored only: print what the OpenSSL build of this mode depends on (the CI cache key)
# make vm-third-party     build libgc, yyjson, picohttpparser and libuv for this mode (no libgc with SANITIZE=1, no libuv off Linux)
# make vm-third-party-key print what those builds depend on (the CI cache key); they rebuild only when it changes
AGC_VERSION := $(shell sed -n 's/^(define version "\(.*\)")$$/\1/p' src/version.rkt)
GC_DIR := vm/third_party/bdwgc
YY_DIR := vm/third_party/yyjson
PICO_DIR := vm/third_party/picohttpparser
UV_DIR := vm/third_party/libuv
OSSL_DIR := vm/third_party/openssl
YY_DEFS := -DYYJSON_DISABLE_WRITER=1 -DYYJSON_DISABLE_INCR_READER=1 -DYYJSON_DISABLE_FILE=1 -DYYJSON_DISABLE_UTILS=1 -DYYJSON_DISABLE_NON_STANDARD=1 -DYYJSON_DISABLE_FAST_FP_CONV=1
VM_SRC := vm/value.c vm/text.c vm/map.c vm/unicode_data.c vm/loader.c vm/builtins.c vm/strings.c vm/numbers.c vm/random.c vm/input.c vm/json.c vm/json_typed.c vm/loop.c vm/files.c vm/stream.c vm/process.c vm/tcp.c vm/tls_openssl.c vm/http_pico.c vm/http_body.c vm/http_client.c vm/interp.c vm/task.c vm/diag.c vm/trace.c
VM_DEPS := $(VM_SRC) vm/agc.h vm/trace.h vm/tls.h vm/net.h vm/http_parse.h src/version.rkt
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
ifeq ($(shell uname -s),Linux)
UV_NAMES := fs-poll idna inet random strscpy strtok thread-common threadpool timer uv-common uv-data-getter-setters version \
  unix/async unix/core unix/dl unix/fs unix/getaddrinfo unix/getnameinfo unix/loop-watcher unix/loop unix/pipe unix/poll \
  unix/process unix/random-devurandom unix/signal unix/stream unix/tcp unix/thread unix/tty unix/udp \
  unix/linux unix/procfs-exepath unix/random-getrandom unix/random-sysctl-linux unix/proctitle
VM_LIBS += -ldl -lrt
endif
UV_DEFS := -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112
VM_WARN := -std=c11 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -DAGC_VERSION='"$(AGC_VERSION)"' -I $(YY_DIR)/src $(YY_DEFS) -I $(UV_DIR)/include -I $(PICO_DIR)
ifeq ($(SANITIZE),1)
VM_CC := clang
VM_CFLAGS := $(VM_WARN) -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all -DAGC_NO_GC
VM_LDFLAGS := -fsanitize=address,undefined $(VM_LIBS)
VM_GC :=
VM_BUILD := build/vm/sanitize
YY_CFLAGS := -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all
OSSL_CFLAGS := -g -fno-omit-frame-pointer
FUZZ_RUNS ?= 30000
else ifeq ($(GC_STRESS),1)
VM_CC := $(CC)
VM_CFLAGS := $(VM_WARN) -O1 -g -I $(GC_DIR)/include -DGC_DEBUG -DAGC_GC_STRESS $(VM_PIC)
VM_LDFLAGS := $(VM_PIE) $(VM_LIBS)
VM_GC := build/vm/gc.o
VM_BUILD := build/vm/gcstress
YY_CFLAGS := -O1 -g $(VM_PIC)
OSSL_CFLAGS := -g
else
VM_CC := $(CC)
VM_CFLAGS := $(VM_WARN) -O2 -I $(GC_DIR)/include -fstack-protector-strong -D_FORTIFY_SOURCE=2 $(VM_PIC)
VM_LDFLAGS := $(VM_HARDEN_LDFLAGS) $(VM_LIBS)
VM_GC := build/vm/gc.o
VM_BUILD := build/vm/release
YY_CFLAGS := -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 $(VM_PIC)
OSSL_CFLAGS := -fstack-protector-strong -D_FORTIFY_SOURCE=2
FUZZ_RUNS ?= 100000
endif
ifeq ($(TRACE),0)
VM_CFLAGS += -DAGC_TRACE_BUILD=0
endif
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
GC_KEY = { echo '$(GC_COMPILE)'; $(CC) --version 2>/dev/null | head -n 1; $(call SUBMODULE_KEY,$(GC_DIR)); }
TP_KEY = { echo '$(YY_COMPILE) | $(PICO_COMPILE) | $(UV_COMPILE) | $(UV_NAMES) | $(AR) rcs'; $(VM_CC) --version 2>/dev/null | head -n 1; \
  $(AR) --version 2>/dev/null | head -n 1; \
  $(call SUBMODULE_KEY,$(YY_DIR)); $(call SUBMODULE_KEY,$(PICO_DIR)); $(call SUBMODULE_KEY,$(UV_DIR)); }
VM_YY := $(VM_BUILD)/yyjson.o
VM_PICO := $(VM_BUILD)/picohttpparser.o
VM_UV := $(if $(UV_NAMES),$(VM_BUILD)/libuv.a)
UV_OBJS := $(patsubst %,$(VM_BUILD)/uv/%.o,$(UV_NAMES))
OSSL_BUILD := $(VM_BUILD)/openssl
OSSL_STAMP := $(VM_BUILD)/openssl-flags
OSSL_OPTS := no-shared no-tests no-docs no-apps no-module no-dso no-engine no-legacy no-autoload-config no-async no-comp \
  no-ssl3 no-dtls no-srp no-quic no-ui-console no-cmp no-ts no-ct no-ocsp no-http no-deprecated
OSSL_ENV := env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOVERRIDES -u CC -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS -u LDLIBS
OSSL_CONFIGURE = $(OSSL_ENV) CC='$(VM_CC)' perl $(CURDIR)/$(OSSL_DIR)/Configure $(OSSL_OPTS) $(OSSL_CFLAGS)
OSSL_SUBMAKE = $(OSSL_ENV) make -C $(OSSL_BUILD) CC='$(VM_CC)' build_libs
OSSL_RECIPE = $(subst ','\'',$(subst $(CURDIR)/,,$(OSSL_CONFIGURE) | $(OSSL_SUBMAKE)))
OSSL_KEY = { echo '$(OSSL_RECIPE)'; $(VM_CC) --version 2>/dev/null | head -n 1; cat $(OSSL_DIR)/VERSION.dat; git -C $(OSSL_DIR) rev-parse HEAD 2>/dev/null || true; }
VM_OPENSSL ?= system
PKG_CONFIG ?= pkg-config
OSSL_MIN := 3.0.0
VM_OSSL :=
OSSL_LINK :=
OSSL_INC :=
OSSL_DEP :=
ifneq ($(UV_NAMES),)
ifeq ($(VM_OPENSSL),vendored)
VM_OSSL := $(OSSL_BUILD)/libssl.a $(OSSL_BUILD)/libcrypto.a
OSSL_LINK := $(VM_OSSL)
OSSL_DEP := $(VM_OSSL)
OSSL_INC := -I $(OSSL_BUILD)/include -I $(OSSL_DIR)/include
else ifeq ($(VM_OPENSSL),system)
OSSL_LINK := $(shell $(PKG_CONFIG) --libs openssl 2>/dev/null)
OSSL_INC := $(shell $(PKG_CONFIG) --cflags openssl 2>/dev/null)
OSSL_DEP := $(VM_BUILD)/openssl-system
else
$(error VM_OPENSSL must be system or vendored, not '$(VM_OPENSSL)')
endif
endif
VM_CFLAGS += $(OSSL_INC)

$(VM_STAMP): FORCE
	@mkdir -p $(VM_BUILD) build/vm
	@echo '$(VM_CC) $(VM_CFLAGS) $(VM_LDFLAGS) openssl=$(VM_OPENSSL) $(OSSL_LINK)' | cmp -s - $@ || echo '$(VM_CC) $(VM_CFLAGS) $(VM_LDFLAGS) openssl=$(VM_OPENSSL) $(OSSL_LINK)' > $@

$(VM_TP_STAMP): FORCE
	@mkdir -p $(VM_BUILD)
	@$(TP_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(GC_STAMP): FORCE
	@mkdir -p build/vm
	@$(GC_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

vm-third-party-key:
	@$(TP_KEY)
	@$(if $(VM_GC),$(GC_KEY))

vm-third-party: $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV)

$(GC_DIR)/extra/gc.c:
	@echo "missing $(GC_DIR): run git submodule update --init" >&2; exit 1

build/vm/gc.o: $(GC_STAMP) | $(GC_DIR)/extra/gc.c
	@mkdir -p build/vm
	$(GC_COMPILE) -c $(GC_DIR)/extra/gc.c -o $@

$(YY_DIR)/src/yyjson.c:
	@echo "missing $(YY_DIR): run git submodule update --init" >&2; exit 1

$(VM_YY): $(VM_TP_STAMP) | $(YY_DIR)/src/yyjson.c
	@mkdir -p $(VM_BUILD)
	$(YY_COMPILE) -c $(YY_DIR)/src/yyjson.c -o $@

$(PICO_DIR)/picohttpparser.c:
	@echo "missing $(PICO_DIR): run git submodule update --init" >&2; exit 1

$(VM_PICO): $(VM_TP_STAMP) | $(PICO_DIR)/picohttpparser.c
	@mkdir -p $(VM_BUILD)
	$(PICO_COMPILE) -c $(PICO_DIR)/picohttpparser.c -o $@

$(UV_DIR)/src/uv-common.c:
	@echo "missing $(UV_DIR): run git submodule update --init" >&2; exit 1

$(VM_BUILD)/uv/%.o: $(VM_TP_STAMP) | $(UV_DIR)/src/uv-common.c
	@mkdir -p $(dir $@)
	$(UV_COMPILE) -c $(UV_DIR)/src/$*.c -o $@

$(VM_BUILD)/libuv.a: $(UV_OBJS) | $(UV_DIR)/src/uv-common.c
	rm -f $@
	$(AR) rcs $@ $(UV_OBJS)

$(OSSL_DIR)/VERSION.dat:
	@echo "missing $(OSSL_DIR): run git submodule update --init" >&2; exit 1

vm-openssl-key: $(OSSL_DIR)/VERSION.dat
	@test '$(VM_OPENSSL)' = vendored || { echo "vm-openssl-key describes the VM_OPENSSL=vendored build; run make -s vm-openssl-key VM_OPENSSL=vendored" >&2; exit 1; }
	@$(OSSL_KEY)

vm-openssl: $(OSSL_DEP)

$(VM_BUILD)/openssl-system: FORCE
	@command -v $(PKG_CONFIG) >/dev/null || { echo "VM_OPENSSL=system needs pkg-config and the OpenSSL 3 development files (Debian: apt install pkg-config libssl-dev), or build with VM_OPENSSL=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --exists openssl || { echo "pkg-config cannot find openssl: install the OpenSSL 3 development files (Debian: libssl-dev), or build with VM_OPENSSL=vendored" >&2; exit 1; }
	@$(PKG_CONFIG) --atleast-version=$(OSSL_MIN) openssl || { echo "the VM needs OpenSSL $(OSSL_MIN) or newer, pkg-config found $$($(PKG_CONFIG) --modversion openssl); install a newer libssl-dev or build with VM_OPENSSL=vendored" >&2; exit 1; }
	@mkdir -p $(VM_BUILD)
	@{ $(PKG_CONFIG) --modversion openssl; echo '$(OSSL_INC) $(OSSL_LINK)'; } > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(OSSL_STAMP): $(OSSL_DIR)/VERSION.dat FORCE
	@mkdir -p $(VM_BUILD)
	@$(OSSL_KEY) > $@.new; if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

$(OSSL_BUILD)/libcrypto.a: $(OSSL_STAMP)
	@perl -MIPC::Cmd -MFile::Copy -e 1 2>/dev/null || { echo "building OpenSSL needs perl 5 with its core modules (Debian: perl)" >&2; exit 1; }
	rm -rf $(OSSL_BUILD)
	mkdir -p $(OSSL_BUILD)
	cd $(OSSL_BUILD) && $(OSSL_CONFIGURE) > configure.log 2>&1 || { cat configure.log; exit 1; }
	$(OSSL_SUBMAKE) -j $(JOBS) > $(OSSL_BUILD)/build.log 2>&1 || { tail -n 40 $(OSSL_BUILD)/build.log; exit 1; }
	touch $@

$(OSSL_BUILD)/libssl.a: $(OSSL_BUILD)/libcrypto.a
	@test -f $@ || { echo "$@ is missing: remove $(OSSL_BUILD) and rebuild" >&2; exit 1; }

dist/agentica-vm$(EXE): $(OSSL_DEP) $(VM_DEPS) vm/main.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(VM_STAMP)
	@mkdir -p dist
	$(VM_CC) $(VM_CFLAGS) -o $@ $(VM_SRC) vm/main.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(OSSL_LINK) $(VM_LDFLAGS) $(VM_ENTRY)

vm: dist/agentica-vm$(EXE)

VM_TESTS := $(patsubst vm/tests/%_test.c,$(VM_BUILD)/%-test$(EXE),$(wildcard vm/tests/*_test.c))

$(VM_BUILD)/%-test$(EXE): $(OSSL_DEP) vm/tests/%_test.c $(VM_DEPS) vm/fuzz.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(VM_STAMP)
	$(VM_CC) $(VM_CFLAGS) -U NDEBUG -o $@ $(VM_SRC) vm/fuzz.c vm/tests/$*_test.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(OSSL_LINK) $(VM_LDFLAGS)

vm-test: $(VM_TESTS)
	for t in $(VM_TESTS); do $$t || exit 1; done

$(VM_BUILD)/agentica-vm-fuzz$(EXE): $(OSSL_DEP) $(VM_DEPS) vm/fuzz.c vm/fuzz_main.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(VM_STAMP)
	$(VM_CC) $(VM_CFLAGS) -o $@ $(VM_SRC) vm/fuzz.c vm/fuzz_main.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(OSSL_LINK) $(VM_LDFLAGS)

vm-fuzz: build $(VM_BUILD)/agentica-vm-fuzz$(EXE)
	@mkdir -p $(VM_BUILD)/corpus
	for f in tests/fixtures/vm/*.agc; do racket src/main.rkt compile $$f -o $(VM_BUILD)/corpus/$$(basename $$f .agc).agcb || exit 1; done
	$(VM_BUILD)/agentica-vm-fuzz $(FUZZ_RUNS) $(VM_BUILD)/corpus/*.agcb

$(VM_BUILD)/agentica-vm$(EXE): $(OSSL_DEP) $(VM_DEPS) vm/main.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(VM_STAMP)
	$(VM_CC) $(VM_CFLAGS) -o $@ $(VM_SRC) vm/main.c $(VM_GC) $(VM_YY) $(VM_PICO) $(VM_UV) $(OSSL_LINK) $(VM_LDFLAGS) $(VM_ENTRY)

vm-gc-stress: build
	$(MAKE) build/vm/gcstress/agentica-vm$(EXE) vm-test GC_STRESS=1 SANITIZE=0
	AGENTICA_VM_BINARY=build/vm/gcstress/agentica-vm$(EXE) AGENTICA_REQUIRE_VM=1 $(RACO) test -j $(JOBS) $(VM_DIFF_TESTS)

vm-unicode:
	racket vm/tools/gen-unicode.rkt vm/unicode_data.c

CLANG_TIDY ?= clang-tidy
VM_LINT_SKIP := vm/unicode_data.c
VM_LINT_SRC := $(filter-out $(VM_LINT_SKIP),$(wildcard vm/*.c vm/tests/*.c))

.PHONY: vm-lint
vm-lint: $(GC_DIR)/extra/gc.c $(YY_DIR)/src/yyjson.c $(PICO_DIR)/picohttpparser.c $(UV_DIR)/src/uv-common.c $(OSSL_DEP)
	@$(CLANG_TIDY) --list-checks -checks=misc-use-internal-linkage | grep -q misc-use-internal-linkage || { echo "clang-tidy 19+ required" >&2; exit 1; }
	$(CLANG_TIDY) --quiet $(VM_LINT_SRC) -- $(VM_WARN) $(OSSL_INC) -I $(GC_DIR)/include
	$(CLANG_TIDY) --quiet $(VM_LINT_SRC) -- $(VM_WARN) $(OSSL_INC) -DAGC_NO_GC -fsanitize=address,undefined
	$(CLANG_TIDY) --quiet $(VM_LINT_SRC) -- $(VM_WARN) $(OSSL_INC) -I $(GC_DIR)/include -DGC_DEBUG -DAGC_GC_STRESS
