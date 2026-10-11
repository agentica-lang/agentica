RACO ?= raco
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
TESTS ?= tests/
VM_DIFF_TESTS = tests/vm-diff-1-test.rkt tests/vm-diff-2-test.rkt tests/vm-diff-3-test.rkt tests/vm-diff-4-test.rkt

.PHONY: build test exe clean test-bdd bench version vm vm-test vm-fuzz vm-gc-stress vm-unicode site site-serve site-sass FORCE

version:
	@racket -e '(require "src/version.rkt") (display version)'

build:
	$(RACO) make src/main.rkt

# All tests, in parallel:      make test
# A subset:                    make test TESTS="tests/lexer-test.rkt tests/parser-test.rkt"
# More or fewer workers:       make test JOBS=8
test: build
	$(RACO) test -j $(JOBS) $(TESTS)

exe: build
	mkdir -p dist
	$(RACO) exe -o dist/agentica src/main.rkt

# Speed check (docs/vm-benchmarks.md): make bench BENCH_ARGS="--runs 3 --size 2"
# dist/agentica is timed only when present; rebuild it with make exe first, or pass --runners evaluator,vm,python
bench: build vm
	python3 benchmarks/run.py $(BENCH_ARGS)

test-bdd: exe
	dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc

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

# The C VM (docs/vm.md section 11). libgc is built from the pinned submodule.
# make vm                 dist/agentica-vm
# make vm-test            C tests in vm/tests/
# make vm SANITIZE=1      clang with ASan and UBSan, no libgc
# make vm-fuzz            mutate compiled fixtures and run them
# make vm-gc-stress       GC-debug build that collects every 64 allocations, on the differential tests
# make vm-unicode         regenerate vm/unicode_data.c from Racket
AGC_VERSION := $(shell sed -n 's/^(define version "\(.*\)")$$/\1/p' src/version.rkt)
GC_DIR := vm/third_party/bdwgc
VM_SRC := vm/value.c vm/text.c vm/map.c vm/unicode_data.c vm/loader.c vm/builtins.c vm/numbers.c vm/random.c vm/input.c vm/interp.c vm/diag.c
GC_SRC := $(wildcard $(GC_DIR)/*.c $(GC_DIR)/include/*.h $(GC_DIR)/include/private/*.h $(GC_DIR)/extra/*.c)
VM_DEPS := $(VM_SRC) vm/agc.h src/version.rkt
EXE :=
VM_PIC := -fPIE
VM_PIE := -pie
VM_HARDEN_LDFLAGS := $(VM_PIE) -Wl,-z,relro,-z,now
VM_LIBS := -lpthread
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
VM_WARN := -std=c11 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -DAGC_VERSION='"$(AGC_VERSION)"'
ifeq ($(SANITIZE),1)
VM_CC := clang
VM_CFLAGS := $(VM_WARN) -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all -DAGC_NO_GC
VM_LDFLAGS := -fsanitize=address,undefined
VM_GC :=
VM_BUILD := build/vm/sanitize
FUZZ_RUNS ?= 30000
else ifeq ($(GC_STRESS),1)
VM_CC := $(CC)
VM_CFLAGS := $(VM_WARN) -O1 -g -I $(GC_DIR)/include -DGC_DEBUG -DAGC_GC_STRESS $(VM_PIC)
VM_LDFLAGS := $(VM_PIE) $(VM_LIBS)
VM_GC := build/vm/gc.o
VM_BUILD := build/vm/gcstress
else
VM_CC := $(CC)
VM_CFLAGS := $(VM_WARN) -O2 -I $(GC_DIR)/include -fstack-protector-strong -D_FORTIFY_SOURCE=2 $(VM_PIC)
VM_LDFLAGS := $(VM_HARDEN_LDFLAGS) $(VM_LIBS)
VM_GC := build/vm/gc.o
VM_BUILD := build/vm/release
FUZZ_RUNS ?= 100000
endif
VM_STAMP := build/vm/flags

$(VM_STAMP): FORCE
	@mkdir -p $(VM_BUILD) build/vm
	@echo '$(VM_CC) $(VM_CFLAGS) $(VM_LDFLAGS)' | cmp -s - $@ || echo '$(VM_CC) $(VM_CFLAGS) $(VM_LDFLAGS)' > $@

$(GC_DIR)/extra/gc.c:
	@echo "missing $(GC_DIR): run git submodule update --init" >&2; exit 1

build/vm/gc.o: $(GC_DIR)/extra/gc.c $(GC_SRC) Makefile
	@mkdir -p build/vm
	$(CC) -std=c11 -O2 $(VM_PIC) -DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION -I $(GC_DIR)/include -c $< -o $@

dist/agentica-vm$(EXE): $(VM_DEPS) vm/main.c $(VM_GC) $(VM_STAMP)
	@mkdir -p dist
	$(VM_CC) $(VM_CFLAGS) -o $@ $(VM_SRC) vm/main.c $(VM_GC) $(VM_LDFLAGS) $(VM_ENTRY)

vm: dist/agentica-vm$(EXE)

VM_TESTS := $(patsubst vm/tests/%_test.c,$(VM_BUILD)/%-test$(EXE),$(wildcard vm/tests/*_test.c))

$(VM_BUILD)/%-test$(EXE): vm/tests/%_test.c $(VM_DEPS) vm/fuzz.c $(VM_GC) $(VM_STAMP)
	$(VM_CC) $(VM_CFLAGS) -U NDEBUG -o $@ $(VM_SRC) vm/fuzz.c $< $(VM_GC) $(VM_LDFLAGS)

vm-test: $(VM_TESTS)
	for t in $(VM_TESTS); do $$t || exit 1; done

$(VM_BUILD)/agentica-vm-fuzz$(EXE): $(VM_DEPS) vm/fuzz.c vm/fuzz_main.c $(VM_GC) $(VM_STAMP)
	$(VM_CC) $(VM_CFLAGS) -o $@ $(VM_SRC) vm/fuzz.c vm/fuzz_main.c $(VM_GC) $(VM_LDFLAGS)

vm-fuzz: build $(VM_BUILD)/agentica-vm-fuzz$(EXE)
	@mkdir -p $(VM_BUILD)/corpus
	for f in tests/fixtures/vm/*.agc; do racket src/main.rkt compile $$f -o $(VM_BUILD)/corpus/$$(basename $$f .agc).agcb || exit 1; done
	$(VM_BUILD)/agentica-vm-fuzz $(FUZZ_RUNS) $(VM_BUILD)/corpus/*.agcb

$(VM_BUILD)/agentica-vm$(EXE): $(VM_DEPS) vm/main.c $(VM_GC) $(VM_STAMP)
	$(VM_CC) $(VM_CFLAGS) -o $@ $(VM_SRC) vm/main.c $(VM_GC) $(VM_LDFLAGS) $(VM_ENTRY)

vm-gc-stress: build
	$(MAKE) build/vm/gcstress/agentica-vm$(EXE) vm-test GC_STRESS=1 SANITIZE=0
	AGENTICA_VM_BINARY=build/vm/gcstress/agentica-vm$(EXE) AGENTICA_REQUIRE_VM=1 $(RACO) test -j 4 $(VM_DIFF_TESTS)

vm-unicode:
	racket vm/tools/gen-unicode.rkt vm/unicode_data.c
