# The C tests and the checks of the VM: vm-test, TSan, GC stress, sanitizers, fuzz, multicore, the vendored-library
# check, clang-tidy and the layer check. Their binaries use the build mode and the objects of mk/vm.mk.

.PHONY: vm-test vm-test-binaries vm-tsan vm-tsan-run test-multicore test-multicore-modules vm-libfuzz vm-libfuzz-run vm-gc-stress vm-trace-off \
  vm-diff-build vm-diff-test sweep-full test-shared vm-jit-test vm-sanitize-jit-test vm-gc-stress-jit vm-jit-self-compile vm-sanitize-build vm-sanitize-test vendored-check vendored-test \
  vm-layers

VM_DIFF_TESTS = $(sort $(wildcard tests/test_vm_diff_*.py))

VM_TESTS := $(patsubst vm/tests/%_test.c,$(VM_BUILD)/%-test$(EXE),$(wildcard vm/tests/*_test.c))
.SECONDARY: $(patsubst vm/tests/%.c,$(VM_OBJ)/tests/%.o,$(wildcard vm/tests/*_test.c))

$(VM_BUILD)/%-test$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/tests/%_test.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

# This test interposes enumeration by compiling the Windows adapter in its own translation unit.
$(VM_BUILD)/windows_remove-test$(EXE): $(OSSL_DEP) $(GC_DEP) $(filter-out $(VM_OBJ)/file_windows.o,$(VM_OBJS)) $(VM_OBJ)/fuzz.o $(VM_OBJ)/tests/windows_remove_test.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

VM_TESTS_NORMAL := $(filter-out $(VM_BUILD)/tree-test$(EXE) $(VM_BUILD)/files_private-test$(EXE) $(VM_BUILD)/windows_remove-test$(EXE),$(VM_TESTS))

vm-test: $(VM_TESTS)
	printf '%s\n' $(VM_TESTS_NORMAL) | xargs -P $(JOBS) -n 1 sh -c '$(VM_TEST_RUNNER) "$$0" || { echo "C test failed: $$0" >&2; exit 255; }'

# TSan over the code that more than one thread touches (docs/vm/10-io-multicore.md §10.2.3, "Order of work"): the inbox, the
# set-once outcome and reference count, the run queue, the wake against the park, a job on the loop, rt->sync, the output
# locks, a timer fired against a wake and a function compiled by several threads at once. The VM is built without
# libgc (AGC_NO_GC), so the collector's own signals are out of the picture; the whole run is checked, so a race fails
# it.
VM_TSAN_TESTS := inbox compute outcome runq task_wake job sync output timers threads net process_threads jit zlib
# vm/tools/tsan.supp: the calls from the system libcrypto, whose own locking TSan cannot see (TLS setup on pool threads).
VM_TSAN_OPTIONS := halt_on_error=1 suppressions=$(CURDIR)/vm/tools/tsan.supp
vm-tsan:
	$(MAKE) $(patsubst %,build/vm/tsan/%-test,$(VM_TSAN_TESTS)) TSAN=1 SANITIZE=0 GC_STRESS=0
	printf '%s\n' $(patsubst %,build/vm/tsan/%-test,$(VM_TSAN_TESTS)) | TSAN_OPTIONS="$(VM_TSAN_OPTIONS)" xargs -n 1 sh -c '$(VM_TEST_RUNNER) "$$0" || { echo "C test failed: $$0" >&2; exit 255; }'

# Programs on four schedulers (tests/test_vm_multicore.py, --schedulers 4 on any machine; the default is one per
# logical core). test-multicore runs them on dist/agentica; vm-tsan-run runs them on a TSan
# binary (no libgc, the front end of the release build), so a race between schedulers or with the I/O thread fails it.
# The module run also sets AGENTICA_TEST_EXECUTABLE to that binary, so the tests that run the command line (`agentica
# test`, `check`) go through TSan too, not through the ASan binary that SANITIZE=1 makes of dist/agentica.
# Both also run the TCP, TLS, HTTP, process, BDD and native-call modules with every VM on four schedulers
# (AGENTICA_VM_TEST_MODULE_SCHEDULERS, read by tests/agentica_test.py); test-multicore-modules runs only those.
VM_MULTICORE_MODULES := tests/test_vm_tcp.py tests/test_vm_tls.py tests/test_vm_http.py tests/test_process.py \
  tests/test_process_lifecycle.py tests/test_bdd.py tests/test_vm_native.py
test-multicore: dist/agentica$(EXE)
	@$(MAKE) --no-print-directory test-py TESTS="tests/test_vm_multicore.py"
	@$(MAKE) --no-print-directory test-multicore-modules

test-multicore-modules: dist/agentica$(EXE)
	@AGENTICA_VM_TEST_MODULE_SCHEDULERS=4 $(MAKE) --no-print-directory test-py TESTS="$(VM_MULTICORE_MODULES)"

vm-tsan-run: dist/agentica$(EXE)
	$(MAKE) build/vm/tsan/agentica$(EXE) TSAN=1 SANITIZE=0 GC_STRESS=0
	AGENTICA_VM_BINARY=build/vm/tsan/agentica$(EXE) AGENTICA_REQUIRE_VM=1 TSAN_OPTIONS="$(VM_TSAN_OPTIONS)" \
	  $(MAKE) --no-print-directory test-py TESTS="tests/test_vm_multicore.py"
	AGENTICA_VM_BINARY=build/vm/tsan/agentica$(EXE) AGENTICA_TEST_EXECUTABLE=$(CURDIR)/build/vm/tsan/agentica$(EXE) \
	  AGENTICA_REQUIRE_VM=1 TSAN_OPTIONS="$(VM_TSAN_OPTIONS)" \
	  AGENTICA_VM_TEST_MODULE_SCHEDULERS=4 $(MAKE) --no-print-directory test-py TESTS="$(VM_MULTICORE_MODULES)"

# The C tests as programs, without running them: windows-docker-build builds them in a container.
vm-test-binaries: $(VM_TESTS)

# libFuzzer (clang only): agc_fuzz_one behind LLVMFuzzerTestOneInput, on objects built with coverage hooks (LIBFUZZ=1).
# With LIBFUZZ_JIT_WRAP (mk/vm.mk, Linux) each input also runs with the JIT (always and on) and is compared with the
# interpreter's run; the link wraps agc_jit_mem_reserve so that the entry point unmaps each input's code memory, and the
# C library's clocks so that it compares only runs that read none (vm/fuzz_libfuzzer.c).
LIBFUZZ_LINK_FLAGS :=
ifeq ($(LIBFUZZ_JIT_WRAP),1)
LIBFUZZ_LINK_FLAGS := -Wl,--wrap=agc_jit_mem_reserve,--wrap=agc_vm_run,--wrap=clock_gettime,--wrap=timespec_get
endif
$(VM_BUILD)/agentica-vm-libfuzz$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/fuzz_libfuzzer.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK) -fsanitize=fuzzer $(LIBFUZZ_LINK_FLAGS)

# The fuzzer links the VM objects and no front end: an internal artifact of build/, never shipped.
LIBFUZZ_DIR := build/vm/libfuzz
vm-libfuzz:
	$(MAKE) $(LIBFUZZ_DIR)/agentica-vm-libfuzz LIBFUZZ=1

# The seed corpus is every fixture compiled by dist/agentica, JOBS at a time.
FUZZ_CORPUS = mkdir -p $(LIBFUZZ_DIR)/seeds && printf '%s\n' tests/fixtures/vm/*.agc | xargs -P $(JOBS) -I{} sh -c \
  'dist/agentica$(EXE) compile "$$1" -o "$(LIBFUZZ_DIR)/seeds/$$(basename "$$1" .agc).agcb"' sh {}

# A bounded run: LIBFUZZ_TIME seconds on LIBFUZZ_JOBS forked workers. New inputs go to corpus/, the compiled fixtures
# stay in seeds/, crash-* files land in crashes/. Each input stops at 10,000 steps and 256 MB (agc_fuzz_one). A crash,
# a leak or an input past the RSS limit (room for twice 256 MB plus ASan's quarantine) ends the run with an error.
# ASAN_OPTIONS turns on the leak check that vm/value.c turns off for the other ASan builds: agc_fuzz_one frees every
# block of an input. Fork mode keeps its jobs' inputs in TMPDIR, set under build/ because /tmp is often a small tmpfs.
# The sub-make runs after dist/agentica, not beside it, because both write build/vm/flags.
# A timeout (an input past LIBFUZZ_TIMEOUT seconds) fails the run too. agc_fuzz_one has no wall clock
# (agc_timeout_length), so its steps bound every wait; but steps do not bound CPU work (a linear builtin on a large
# string once per step), so a timeout can also be a slow input to triage. Fork mode saves a corpus or seed input that
# fails its first pass and goes on without counting it, so the run also fails when crashes/ got a new crash, leak,
# timeout or oom file (not a slow-unit one: an input slower than 10 s but under LIBFUZZ_TIMEOUT is no failure).
LIBFUZZ_TIME ?= 60
LIBFUZZ_TIMEOUT ?= 10
LIBFUZZ_JOBS ?= 1
LIBFUZZ_RSS_MB ?= 2048
LIBFUZZ_FLAGS ?=
vm-libfuzz-run: dist/agentica$(EXE)
	$(FUZZ_CORPUS)
	$(MAKE) vm-libfuzz
	@mkdir -p $(LIBFUZZ_DIR)/corpus $(LIBFUZZ_DIR)/crashes $(LIBFUZZ_DIR)/tmp
	touch $(LIBFUZZ_DIR)/tmp/started; status=0; \
	ASAN_OPTIONS=detect_leaks=1:allocator_may_return_null=1 TMPDIR=$(CURDIR)/$(LIBFUZZ_DIR)/tmp \
	  $(LIBFUZZ_DIR)/agentica-vm-libfuzz -fork=$(LIBFUZZ_JOBS) -ignore_timeouts=0 \
	  -ignore_ooms=0 -ignore_crashes=0 -max_total_time=$(LIBFUZZ_TIME) -rss_limit_mb=$(LIBFUZZ_RSS_MB) -timeout=$(LIBFUZZ_TIMEOUT) \
	  -artifact_prefix=$(LIBFUZZ_DIR)/crashes/ -print_final_stats=1 $(LIBFUZZ_FLAGS) \
	  $(LIBFUZZ_DIR)/corpus $(LIBFUZZ_DIR)/seeds || status=$$?; \
	new=$$(find $(LIBFUZZ_DIR)/crashes -type f -newer $(LIBFUZZ_DIR)/tmp/started \( -name 'crash-*' -o -name 'leak-*' \
	  -o -name 'timeout-*' -o -name 'oom-*' \)); \
	if [ -n "$$new" ]; then echo "vm-libfuzz-run: new failure files:"; echo "$$new"; [ $$status -ne 0 ] || status=1; fi; \
	exit $$status

# The golden tests compile with dist/agentica and run on the GC stress binary (AGENTICA_VM_BINARY): the front end does not
# run under the stress. The binary links the stage2 that dist/agentica was built from.
vm-gc-stress: dist/agentica$(EXE)
	$(MAKE) build/vm/gcstress/agentica$(EXE) vm-test GC_STRESS=1 SANITIZE=0
	AGENTICA_VM_BINARY=build/vm/gcstress/agentica$(EXE) AGENTICA_REQUIRE_VM=1 AGENTICA_SWEEP=$${AGENTICA_SWEEP:-sampled} \
	  $(MAKE) --no-print-directory test-py TESTS="$(VM_DIFF_TESTS)"

# The same goldens on the GC stress binary with AGENTICA_JIT=always (weekly in sweep.yml).
vm-gc-stress-jit: dist/agentica$(EXE)
	$(MAKE) build/vm/gcstress/agentica$(EXE) GC_STRESS=1 SANITIZE=0
	AGENTICA_VM_BINARY=build/vm/gcstress/agentica$(EXE) AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=always \
	  AGENTICA_SWEEP=$${AGENTICA_SWEEP:-sampled} $(MAKE) --no-print-directory test-py TESTS="$(VM_DIFF_TESTS)"

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
VM_PY_TESTS = $(VM_DIFF_TESTS) tests/test_vm_stack.py tests/test_single_binary.py tests/test_std_analysis.py tests/test_vm_stop.py tests/test_vm_stdout.py tests/test_vm_file_lines.py tests/test_vm_os.py tests/test_vm_tcp.py tests/test_vm_tls.py tests/test_vm_http.py tests/test_vm_test_protocol.py tests/test_vm_child_channel.py tests/test_vm_child_channel_posix.py tests/test_vm_channel.py tests/test_vm_trace.py tests/test_vm_multicore.py tests/test_vm_native.py tests/test_vm_jit.py
SANITIZE_JOBS ?= 4

# The same modules with the shared-state locks on at one scheduler (AGENTICA_VM_TEST_SHARED=1, test-only; the module
# knob pins one scheduler, which is not the default): the lock checks of agc_sync_assert and the owner token then run on
# every builtin, so a builtin that touches shared state without its lock fails here. The goldens sweep only the ends
# (AGENTICA_SWEEP=ends: --max-steps 1, T - 1, T and past T): the full sweep runs in make test and vm-jit-test.
test-shared: dist/agentica$(EXE)
	AGENTICA_SWEEP=ends AGENTICA_VM_TEST_SHARED=1 AGENTICA_VM_TEST_MODULE_SCHEDULERS=1 $(MAKE) --no-print-directory test-py TESTS="$(VM_PY_TESTS)" JOBS=$(JOBS)

# The goldens with their --max-steps sweeps, the stack traces and the programs on four schedulers, with each function
# the JIT can compile compiled at its first entry (AGENTICA_JIT=always, docs/future/22-jit.md §22): no output may
# depend on the tier. Then half of the golden shards with AGENTICA_JIT=on, the mode that compiles hot functions only:
# the odd or the even shards by the last hex digit of GITHUB_SHA (else HEAD), so successive commits cover all of them;
# VM_JIT_ON_TESTS names others.
VM_JIT_ON_TESTS ?=
vm-jit-test: dist/agentica$(EXE)
	AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=always $(MAKE) --no-print-directory test-py \
	  TESTS="$(VM_DIFF_TESTS) tests/test_vm_stack.py tests/test_vm_multicore.py"
	@tests="$(VM_JIT_ON_TESTS)"; if [ -z "$$tests" ]; then \
	  sha=$${GITHUB_SHA:-$$(git rev-parse HEAD 2>/dev/null || echo 0)}; parity=$$(( 0x$$(printf '%s' "$$sha" | tail -c 1) % 2 )); \
	  tests=$$(printf '%s\n' $(VM_DIFF_TESTS) | awk -v p=$$parity 'NR % 2 == p'); fi; \
	  echo "vm-jit-test: AGENTICA_JIT=on over" $$tests; \
	  AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=on $(MAKE) --no-print-directory test-py TESTS="$$tests"

# The goldens and the stack traces with AGENTICA_JIT=always on the sanitizer binary that an earlier step built
# (SANITIZE=1, as vm-sanitize-test), with the sampled sweep: it checks the C helpers that compiled code calls and the
# exits it takes under ASan and UBSan; the emitted machine code itself is not instrumented, so a fault there shows only
# as a crash. Weekly in sweep.yml.
vm-sanitize-jit-test: vm-sanitize-build
	AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=always AGENTICA_SWEEP=$${AGENTICA_SWEEP:-sampled} $(MAKE) --no-print-directory test-py \
	  TESTS="$(VM_DIFF_TESTS) tests/test_vm_stack.py" JOBS=$(SANITIZE_JOBS)


# The front end compiling itself with the JIT on it (the test-only AGENTICA_VM_TEST_FRONT_END_JIT, vm/launch.c), once
# with `on` and once with `always`: each must give stage2 byte for byte, and the jit trace must show compiled functions
# (so a hook that stopped working cannot pass). Weekly in sweep.yml.
vm-jit-self-compile: $(STAGE_DIR)/stage3.agcb dist/agentica$(EXE)
	@mkdir -p $(STAGE_DIR)/jit
	for mode in on always; do \
	  out=$(STAGE_DIR)/jit/$$mode; rm -f $$out.trace $$out.agcb; \
	  AGENTICA_VM_TEST_FRONT_END_JIT=$$mode AGENTICA_VM_TRACE=jit AGENTICA_VM_TRACE_FILE=$$out.trace \
	    $(RUN_PROGRAM) dist/agentica$(EXE) compile $(FRONT_END_SRC) -o $$out.agcb || exit 1; \
	  grep -q ' jit compile ' $$out.trace || { echo "vm-jit-self-compile: the JIT compiled nothing under --jit $$mode" >&2; exit 1; }; \
	  cmp $(STAGE_DIR)/stage2.agcb $$out.agcb || { echo "vm-jit-self-compile: the front end under --jit $$mode compiles another front end" >&2; exit 1; }; \
	done

vm-sanitize-build: dist/agentica$(EXE)

vm-sanitize-test: vm-sanitize-build
	@$(MAKE) --no-print-directory test-py TESTS="$(VM_PY_TESTS)" JOBS=$(SANITIZE_JOBS)

# The shared libraries a binary loads, one per line, for vendored-check: ELF NEEDED entries, Mach-O load commands, or
# PE imports.
OBJDUMP ?= objdump
ifeq ($(VM_OS),Windows_NT)
VM_DYNAMIC_DEPS = $(OBJDUMP) -p $(1) | sed -n 's/.*DLL Name: *//p'
else ifeq ($(shell uname -s),Darwin)
VM_DYNAMIC_DEPS = otool -L $(1) | sed 1d
else
VM_DYNAMIC_DEPS = readelf -d $(1) | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
endif
VENDORED_BIN := build/vm/release/agentica$(EXE)

# Link the VM against the vendored OpenSSL, libgc and zlib and check that each is static and the version is the submodule's.
# On Windows it also checks that the binary does not need the MSYS2 runtime (msys-2.0.dll). The libz match needs the
# separator class: without it libzstd would match too.
vendored-check:
	$(MAKE) -j$(JOBS) $(VENDORED_BIN) AGENTICA_OPENSSL=vendored AGENTICA_GC=vendored AGENTICA_ZLIB=vendored
	@deps=$$($(call VM_DYNAMIC_DEPS,$(VENDORED_BIN))); \
	  test -n "$$deps" || { echo "cannot list the shared libraries of $(VENDORED_BIN)" >&2; exit 1; }; \
	  if printf '%s\n' "$$deps" | grep -qE '(^|[/[:space:]])lib(ssl|crypto|gc|z)[-.0-9]|zlib1[.]dll|msys-2[.]0[.]dll'; then \
	    echo "the vendored binary links OpenSSL, libgc, zlib or the MSYS2 runtime dynamically:" >&2; printf '%s\n' "$$deps" >&2; exit 1; fi
	@ossl=$$(awk -F= '/^(MAJOR|MINOR|PATCH)=/ { printf "%s%s", sep, $$2; sep = "." }' vm/third_party/openssl/VERSION.dat); \
	  $(RUN_PROGRAM) $(VENDORED_BIN) run --version | grep -qF "OpenSSL $$ossl" || { echo "the vendored binary does not report OpenSSL $$ossl" >&2; exit 1; }

# vendored-check, then the TLS and HTTP tests on that binary
vendored-test: vendored-check
	AGENTICA_VM_BINARY=$(VENDORED_BIN) $(MAKE) --no-print-directory test-py JOBS=2 TESTS="tests/test_vm_tls.py tests/test_vm_http.py"

CLANG_TIDY ?= clang-tidy
# vm/unicode_data.c is frozen table data (see its header), so it is not linted
VM_LINT_SKIP := vm/unicode_data.c
VM_LINT_SRC := $(filter-out $(VM_LINT_SKIP),$(wildcard vm/*.c vm/jit/*.c vm/tests/*.c))

.PHONY: vm-lint vm-lint-check vm-lint-release vm-lint-sanitize vm-lint-gcstress
vm-lint: vm-lint-release vm-lint-sanitize vm-lint-gcstress

vm-lint-check: $(OSSL_DEP) $(GC_DIR)/extra/gc.c $(YY_DIR)/src/yyjson.c $(PICO_DIR)/picohttpparser.c $(UV_DIR)/src/uv-common.c $(FFI_HEADERS)
	@$(CLANG_TIDY) --version
	@major=$$($(CLANG_TIDY) --version | sed -n 's/.*version \([0-9][0-9]*\).*/\1/p' | head -n 1); \
	  if [ -z "$$major" ] || [ "$$major" -lt 19 ]; then echo "clang-tidy $${major:-unknown} is too old: misc-use-internal-linkage needs clang-tidy 19 or newer" >&2; exit 1; fi
	@$(CLANG_TIDY) --list-checks -checks=misc-use-internal-linkage | grep -q misc-use-internal-linkage || { echo "clang-tidy 19+ required" >&2; exit 1; }

vm-lint-release vm-lint-sanitize vm-lint-gcstress: vm-lint-check

# With libffi (Linux x86_64, Windows x64, macOS) the lint reads vm/ffi_libffi.c, and vm/ffi_none.c is empty, as in the build.
LINT = printf '%s\n' $(VM_LINT_SRC) | xargs -P $(JOBS) -I{} $(CLANG_TIDY) --quiet {} -- $(VM_WARN) $(OSSL_INC) \
  $(if $(FFI_NAMES),-DAGC_FFI -I $(FFI_INC))

vm-lint-release:
	$(LINT) -I $(GC_DIR)/include

vm-lint-sanitize:
	$(LINT) -DAGC_NO_GC -fsanitize=address,undefined

vm-lint-gcstress:
	$(LINT) -I $(GC_DIR)/include -DGC_DEBUG -DAGC_GC_STRESS

vm-layers: $(VM_OBJS) $(VM_OBJ)/agentica.o $(VM_OBJ)/launch.o
	for h in vm/*.h vm/jit/*.h; do $(VM_CC) $(VM_CFLAGS) -fsyntax-only -x c -include $$h /dev/null || exit 1; done
	sh vm/tools/check-layers.sh $(VM_OBJ)
	sh vm/tools/check-layers-test.sh $(VM_OBJ) $(VM_CC) $(VM_CFLAGS)
