# The C tests and the checks of the VM: vm-test, TSan, GC stress, sanitizers, fuzz, multicore, the vendored-library
# check, clang-tidy and the layer check. Their binaries use the build mode and the objects of mk/vm.mk.

.PHONY: coverage vm-test vm-test-binaries vm-tsan vm-tsan-run vm-tsan-native test-multicore test-multicore-modules vm-libfuzz vm-libfuzz-run vm-gc-stress vm-trace-off \
  vm-diff-build vm-diff-test sweep-full test-shared vm-jit-test vm-sanitize-jit-test vm-gc-stress-jit vm-jit-self-compile vm-sanitize-build vm-sanitize-test vendored-check vendored-test \
  vm-layers layout-check

VM_DIFF_TESTS = $(sort $(wildcard tests/test_vm_diff_*.py))

VM_TESTS := $(patsubst vm/tests/%_test.c,$(VM_BUILD)/%-test$(EXE),$(wildcard vm/tests/*_test.c))
.SECONDARY: $(patsubst vm/tests/%.c,$(VM_OBJ)/tests/%.o,$(wildcard vm/tests/*_test.c))

$(VM_BUILD)/%-test$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/tests/%_test.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

# This test interposes enumeration by compiling the Windows adapter in its own translation unit.
$(VM_BUILD)/windows_remove-test$(EXE): $(OSSL_DEP) $(GC_DEP) $(filter-out $(VM_OBJ)/file_windows.o,$(VM_OBJS)) $(VM_OBJ)/fuzz.o $(VM_OBJ)/tests/windows_remove_test.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK)

# The native module that native_module-test opens as a shared library, next to it: tests/fixtures/native/module_demo.c
# built like a module of a package, with no symbol of the VM to link against (-z defs on Linux finds any).
NATIVE_DEMO := $(VM_BUILD)/$(if $(filter Windows_NT,$(VM_OS)),module_demo.dll,$(if $(filter Darwin,$(shell uname -s)),libmodule_demo.dylib,libmodule_demo.so))
# In the TSan mode the demo is built with TSan too and takes the runtime from the test, so it is linked without -z defs.
NATIVE_DEMO_FLAGS := $(if $(filter Windows_NT,$(VM_OS)),-shared,$(if $(filter Darwin,$(shell uname -s)),-dynamiclib,-shared -fPIC -Wl,-z,defs))
NATIVE_DEMO_CC := $(CC)
ifeq ($(TSAN),1)
NATIVE_DEMO_FLAGS := -shared -fPIC -g -fno-omit-frame-pointer -fsanitize=thread
NATIVE_DEMO_CC := $(VM_CC)
endif
$(NATIVE_DEMO): tests/fixtures/native/module_demo.c vm/agentica_native.h
	@mkdir -p $(dir $@)
	$(NATIVE_DEMO_CC) -std=c11 -O1 -fvisibility=hidden $(NATIVE_DEMO_FLAGS) -o $@ $<
$(VM_BUILD)/native_module-test$(EXE): $(NATIVE_DEMO)

VM_TESTS_NORMAL := $(filter-out $(VM_BUILD)/tree-test$(EXE) $(VM_BUILD)/files_private-test$(EXE) $(VM_BUILD)/windows_remove-test$(EXE),$(VM_TESTS))

vm-test: $(VM_TESTS)
	printf '%s\n' $(VM_TESTS_NORMAL) | xargs -P $(JOBS) -n 1 sh -c '$(VM_TEST_RUNNER) "$$0" || { echo "C test failed: $$0" >&2; exit 255; }'

# TSan over the code that more than one thread touches (docs/vm/10-io-multicore.md §10.2.3, "Order of work"): the inbox, the
# set-once outcome and reference count, the run queue, the wake against the park, a job on the loop, rt->sync, the output
# locks, a timer fired against a wake and a function compiled by several threads at once. The VM is built without
# libgc (AGC_NO_GC), so the collector's own signals are out of the picture; the whole run is checked, so a race fails
# it.
VM_TSAN_TESTS := inbox compute outcome runq task_wake job sync output timers threads net process_threads jit zlib ats native_module
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
# test-multicore also runs the TCP, DNS, TLS, HTTP, process, BDD, native-call and coverage modules with every VM on four
# schedulers (AGENTICA_VM_TEST_MODULE_SCHEDULERS, read by tests/agentica_test.py); test-multicore-modules runs only
# those.
# vm-tsan-run runs them too, except the native-call module, which vm-tsan-native runs with TSan-built peers.
VM_MULTICORE_MODULES := tests/test_vm_tcp.py tests/test_vm_dns.py tests/test_vm_tls.py tests/test_vm_http.py tests/test_vm_websocket.py tests/test_vm_http_proxy.py tests/test_process.py \
  tests/test_process_lifecycle.py tests/test_bdd.py tests/test_vm_native.py tests/test_cli_coverage.py
test-multicore: dist/agentica$(EXE)
	@$(MAKE) --no-print-directory test-py TESTS="tests/test_vm_multicore.py"
	@$(MAKE) --no-print-directory test-multicore-modules

test-multicore-modules: dist/agentica$(EXE)
	@AGENTICA_VM_TEST_MODULE_SCHEDULERS=4 $(MAKE) --no-print-directory test-py TESTS="$(VM_MULTICORE_MODULES)"

# The native and FFI modules on the TSan binary, on two and then four schedulers (#1169). tests/test_vm_native.py
# builds its peers (tests/fixtures/native/*.c, the module demo, examples/ffi/demo.c) with -fsanitize=thread when the VM
# under test is this binary, so a race in a peer's C or between the peer and the VM fails the run. The TSan control
# (tsan_finalize_control.c) is a program of its own with its own TSAN_OPTIONS, and the finalization hook stays
# uninstrumented. vm-tsan-run leaves these modules to this target. AGENTICA_TSAN_PEERS=1 makes tests/test_vm_native.py
# fail at import if its peers would not be built with TSan. TSAN_NATIVE_SCHEDULERS=4 runs one count (a CI job each).
VM_TSAN_NATIVE_MODULES := tests/test_vm_native.py tests/test_vm_native_module.py tests/test_examples_ffi.py
TSAN_NATIVE_SCHEDULERS ?= 2 4
vm-tsan-native: dist/agentica$(EXE)
	$(MAKE) build/vm/tsan/agentica$(EXE) TSAN=1 SANITIZE=0 GC_STRESS=0
	for n in $(TSAN_NATIVE_SCHEDULERS); do \
	  echo "vm-tsan-native: $$n schedulers"; \
	  AGENTICA_VM_BINARY=build/vm/tsan/agentica$(EXE) AGENTICA_TEST_EXECUTABLE=$(CURDIR)/build/vm/tsan/agentica$(EXE) \
	    AGENTICA_REQUIRE_VM=1 AGENTICA_TSAN_PEERS=1 TSAN_OPTIONS="$(VM_TSAN_OPTIONS)" AGENTICA_VM_TEST_MODULE_SCHEDULERS=$$n \
	    $(MAKE) --no-print-directory test-py SHARD= TESTS="$(VM_TSAN_NATIVE_MODULES)" || exit 1; \
	done

# SHARD=I/N runs shard I of N of these modules (tools/shard_tests.py, the tsan column of tests/shard_weights.txt: the CI
# shards), the two runs below together being one list. The inner make gets SHARD= so that it does not split its list again.
TSAN_RUN_ALONE := tests/test_vm_multicore.py
TSAN_RUN_MODULES := $(filter-out $(VM_TSAN_NATIVE_MODULES),$(VM_MULTICORE_MODULES))
TSAN_RUN_PICKED = $(if $(SHARD),$(shell $(PYTHON) tools/shard_tests.py --weights tsan $(SHARD) $(TSAN_RUN_ALONE) $(TSAN_RUN_MODULES)),$(TSAN_RUN_ALONE) $(TSAN_RUN_MODULES))
vm-tsan-run: dist/agentica$(EXE)
	@: $(SHARD_CHECK)
	@if [ -n "$(SHARD)" ] && [ -z "$(strip $(TSAN_RUN_PICKED))" ]; then \
	  echo "SHARD=$(SHARD) selected no module (tools/shard_tests.py failed, or the shard is empty): nothing would run" >&2; exit 1; \
	fi
	$(MAKE) build/vm/tsan/agentica$(EXE) TSAN=1 SANITIZE=0 GC_STRESS=0
	$(if $(filter $(TSAN_RUN_ALONE),$(TSAN_RUN_PICKED)),AGENTICA_VM_BINARY=build/vm/tsan/agentica$(EXE) AGENTICA_REQUIRE_VM=1 TSAN_OPTIONS="$(VM_TSAN_OPTIONS)" \
	  $(MAKE) --no-print-directory test-py SHARD= TESTS="$(TSAN_RUN_ALONE)")
	$(if $(filter-out $(TSAN_RUN_ALONE),$(TSAN_RUN_PICKED)),AGENTICA_VM_BINARY=build/vm/tsan/agentica$(EXE) AGENTICA_TEST_EXECUTABLE=$(CURDIR)/build/vm/tsan/agentica$(EXE) \
	  AGENTICA_REQUIRE_VM=1 TSAN_OPTIONS="$(VM_TSAN_OPTIONS)" \
	  AGENTICA_VM_TEST_MODULE_SCHEDULERS=4 $(MAKE) --no-print-directory test-py SHARD= TESTS="$(filter-out $(TSAN_RUN_ALONE),$(TSAN_RUN_PICKED))")

# The C tests as programs, without running them: windows-docker-build builds them in a container.
vm-test-binaries: $(VM_TESTS)

# libFuzzer (clang only): agc_fuzz_one behind LLVMFuzzerTestOneInput, on objects built with coverage hooks (LIBFUZZ=1).
# With LIBFUZZ_JIT_WRAP (mk/vm.mk, Linux) each input also runs with the JIT (always and on) and is compared with the
# interpreter's run; the link wraps agc_jit_mem_reserve so that the entry point unmaps each input's code memory, the
# C library's clocks so that it compares only runs that read none, and agc_secure_random so that SecureRandom draws
# the same fixed stream in every run (vm/fuzz_libfuzzer.c).
LIBFUZZ_LINK_FLAGS :=
ifeq ($(LIBFUZZ_JIT_WRAP),1)
LIBFUZZ_LINK_FLAGS := -Wl,--wrap=agc_jit_mem_reserve,--wrap=agc_vm_run,--wrap=clock_gettime,--wrap=timespec_get \
  -Wl,--wrap=agc_secure_random
endif
$(VM_BUILD)/agentica-vm-libfuzz$(EXE): $(OSSL_DEP) $(GC_DEP) $(VM_OBJS) $(VM_OBJ)/fuzz.o $(VM_OBJ)/fuzz_libfuzzer.o $(VM_LINK_LIBS) $(VM_STAMP)
	$(VM_LINK) -fsanitize=fuzzer $(LIBFUZZ_LINK_FLAGS)

# The fuzzer links the VM objects and no front end: an internal artifact of build/, never shipped.
LIBFUZZ_DIR := build/vm/libfuzz
vm-libfuzz:
	$(MAKE) $(LIBFUZZ_DIR)/agentica-vm-libfuzz LIBFUZZ=1

# The seed corpus is every fixture compiled by dist/agentica, JOBS at a time, and the seeds of tests/fixtures/fuzz/.
# The fuzz driver derives no KDF key (vm/crypto.c refuses the job under rt->no_files), so kdf is a seed too.
FUZZ_SEEDS = $(wildcard tests/fixtures/vm/*.agc tests/fixtures/fuzz/*.agc)
FUZZ_CORPUS = mkdir -p $(LIBFUZZ_DIR)/seeds && printf '%s\n' $(FUZZ_SEEDS) | xargs -P $(JOBS) -I{} sh -c \
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
# First the native_module seed must run to its end through the driver (AGC_FUZZ_SHOW, vm/fuzz_libfuzzer.c): a seed
# whose module call fails to bind would leave the module's getters and constructors unfuzzed.
LIBFUZZ_TIME ?= 60
LIBFUZZ_TIMEOUT ?= 10
LIBFUZZ_JOBS ?= 1
LIBFUZZ_RSS_MB ?= 2048
LIBFUZZ_FLAGS ?=
vm-libfuzz-run: dist/agentica$(EXE)
	$(FUZZ_CORPUS)
	$(MAKE) vm-libfuzz
	AGC_FUZZ_SHOW=1 $(LIBFUZZ_DIR)/agentica-vm-libfuzz $(LIBFUZZ_DIR)/seeds/native_module.agcb 2>&1 | \
	  grep -q 'end kind=0 exit=0' || { echo "vm-libfuzz-run: the native_module seed does not run to its end"; exit 1; }
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

# Line and function coverage of vm/ (#1234): the COVERAGE=1 binary and C tests (mk/vm.mk; gcc, or COVERAGE_CC=clang), the C
# tests and the goldens on them (COVERAGE_TESTS, compiled by dist/agentica; the sweep is `ends` unless AGENTICA_SWEEP says
# otherwise), then build/coverage/lcov.info (tools/coverage.py, without vm/third_party and vm/tests) and build/coverage/html
# when genhtml (lcov) is installed. Each run starts from zero counters and no old report. A failed test still gets its
# report written, and the target then fails. The readers must match the compiler: GCOV is gcov-MAJOR of the gcc when there
# is one, and LLVM_PROFDATA and LLVM_COV are the ones next to the clang, else NAME-MAJOR. genhtml 2.x checks the report
# against the sources and stops on what gcov's own counts can give (a function hit with no line hit, an inline line
# number past the end of a header); those two checks are turned off there, while a missing or unreadable report still
# fails.
COVERAGE_DIR := build/coverage
COVERAGE_TESTS ?= $(VM_DIFF_TESTS)
COVERAGE_COMPILER = $(or $(COVERAGE_CC),gcc)
COVERAGE_IS_CLANG = $(findstring clang,$(notdir $(COVERAGE_COMPILER)))
COVERAGE_MAJOR = $$($(COVERAGE_COMPILER) -dumpversion 2>/dev/null | cut -d. -f1)
GCOV ?= $(firstword $(shell command -v gcov-$(COVERAGE_MAJOR) 2>/dev/null) gcov)
COVERAGE_LLVM_TOOL = $(firstword $(shell p=$$($(COVERAGE_COMPILER) -print-prog-name=$(1) 2>/dev/null); \
  command -v "$$p" 2>/dev/null || command -v $(1)-$(COVERAGE_MAJOR) 2>/dev/null) $(1))
LLVM_PROFDATA ?= $(if $(COVERAGE_IS_CLANG),$(call COVERAGE_LLVM_TOOL,llvm-profdata),llvm-profdata)
LLVM_COV ?= $(if $(COVERAGE_IS_CLANG),$(call COVERAGE_LLVM_TOOL,llvm-cov),llvm-cov)
COVERAGE_ENV = LLVM_PROFILE_FILE='$(CURDIR)/$(COVERAGE_DIR)/profraw/%4m.profraw'
COVERAGE_MODE = COVERAGE=1 SANITIZE=0 TSAN=0 GC_STRESS=0 LIBFUZZ=0
COVERAGE_TEST_BINARIES = $(patsubst $(VM_BUILD)/%,build/vm/coverage/%,$(VM_TESTS_NORMAL))
COVERAGE_REPORT = $(if $(COVERAGE_IS_CLANG),$(PYTHON) tools/coverage.py clang $(LLVM_PROFDATA) $(LLVM_COV) \
  $(COVERAGE_DIR)/profraw $(COVERAGE_DIR)/lcov.info build/vm/coverage/agentica$(EXE) $(COVERAGE_TEST_BINARIES),$(PYTHON) \
  tools/coverage.py gcc $(GCOV) build/vm/coverage/obj $(COVERAGE_DIR)/lcov.info)
coverage: dist/agentica$(EXE)
	mkdir -p $(COVERAGE_DIR)/profraw
	find $(COVERAGE_DIR)/profraw -name '*.profraw' -delete
	find $(COVERAGE_DIR) -maxdepth 1 -name lcov.info -delete
	if [ -d $(COVERAGE_DIR)/html ]; then find $(COVERAGE_DIR)/html -delete; fi
	if [ -d build/vm/coverage ]; then find build/vm/coverage -name '*.gcda' -delete; fi
	$(MAKE) build/vm/coverage/agentica$(EXE) vm-test-binaries $(COVERAGE_MODE)
	status=0; \
	$(COVERAGE_ENV) $(MAKE) --no-print-directory vm-test $(COVERAGE_MODE) || status=1; \
	$(COVERAGE_ENV) AGENTICA_VM_BINARY=build/vm/coverage/agentica$(EXE) AGENTICA_REQUIRE_VM=1 \
	  AGENTICA_SWEEP=$${AGENTICA_SWEEP:-ends} $(MAKE) --no-print-directory test-py TESTS="$(COVERAGE_TESTS)" || status=1; \
	$(COVERAGE_REPORT) || exit 1; \
	echo "coverage: $(COVERAGE_DIR)/lcov.info"; \
	if command -v genhtml >/dev/null; then \
	  lcov_major=$$(genhtml --version | sed -n 's/.*LCOV version \([0-9][0-9]*\).*/\1/p'); \
	  ignore=; if [ "$${lcov_major:-1}" -ge 2 ]; then ignore="--ignore-errors inconsistent,range"; fi; \
	  genhtml --quiet $$ignore --output-directory $(COVERAGE_DIR)/html $(COVERAGE_DIR)/lcov.info || exit 1; \
	fi; \
	exit $$status

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

# The golden tests with the full --max-steps sweep (weekly in CI), with AGENTICA_JIT=off: the interpreter alone, since
# `on`, the default, runs in every other suite
sweep-full: vm-diff-build
	AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=off AGENTICA_SWEEP=full $(MAKE) --no-print-directory test-py TESTS="$(VM_DIFF_TESTS)"

# The test modules that run against the built binary (make test-py runs them; the ASan job runs them on the sanitizer
# binary). They need dist/agentica, which make builds first; without it a module skips locally and fails in CI.
VM_PY_TESTS = $(VM_DIFF_TESTS) tests/test_vm_stack.py tests/test_single_binary.py tests/test_std_analysis.py tests/test_vm_stop.py tests/test_vm_stdout.py tests/test_vm_file_lines.py tests/test_vm_os.py tests/test_vm_tcp.py tests/test_vm_dns.py tests/test_vm_tls.py tests/test_vm_http.py tests/test_vm_websocket.py tests/test_vm_http_proxy.py tests/test_vm_test_protocol.py tests/test_vm_child_channel.py tests/test_vm_child_channel_posix.py tests/test_vm_channel.py tests/test_vm_trace.py tests/test_vm_multicore.py tests/test_vm_native.py tests/test_vm_native_module.py tests/test_vm_jit.py
SANITIZE_JOBS ?= 4

# The same modules with the shared-state locks on at one scheduler (AGENTICA_VM_TEST_SHARED=1, test-only; the module
# knob pins one scheduler, which is not the default): the lock checks of agc_sync_assert and the owner token then run on
# every builtin, so a builtin that touches shared state without its lock fails here. The goldens sweep only the ends
# (AGENTICA_SWEEP=ends: --max-steps 1, T - 1, T and past T): the full sweep runs in make test and vm-jit-test.
test-shared: dist/agentica$(EXE)
	AGENTICA_SWEEP=ends AGENTICA_VM_TEST_SHARED=1 AGENTICA_VM_TEST_MODULE_SCHEDULERS=1 $(MAKE) --no-print-directory test-py TESTS="$(VM_PY_TESTS)" JOBS=$(JOBS)

# The goldens with their --max-steps sweeps, the stack traces and the programs on four schedulers, with each function
# the JIT can compile compiled at its first entry (AGENTICA_JIT=always,
# docs/vm/05-values-execution-builtins.md §6.4): no output may depend on the tier. Then half of the golden shards with
# AGENTICA_JIT=off, the interpreter alone (make test runs them with `on`, the default): the odd or the even shards by
# the last hex digit of GITHUB_SHA (else HEAD), so successive commits cover all of them; VM_JIT_OFF_TESTS names others.
VM_JIT_OFF_TESTS ?=
vm-jit-test: dist/agentica$(EXE)
	AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=always $(MAKE) --no-print-directory test-py \
	  TESTS="$(VM_DIFF_TESTS) tests/test_vm_stack.py tests/test_vm_multicore.py"
	@tests="$(VM_JIT_OFF_TESTS)"; if [ -z "$$tests" ]; then \
	  sha=$${GITHUB_SHA:-$$(git rev-parse HEAD 2>/dev/null || echo 0)}; parity=$$(( 0x$$(printf '%s' "$$sha" | tail -c 1) % 2 )); \
	  tests=$$(printf '%s\n' $(VM_DIFF_TESTS) | awk -v p=$$parity 'NR % 2 == p'); fi; \
	  echo "vm-jit-test: AGENTICA_JIT=off over" $$tests; \
	  AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=off $(MAKE) --no-print-directory test-py TESTS="$$tests"

# The goldens and the stack traces with AGENTICA_JIT=always on the sanitizer binary that an earlier step built
# (SANITIZE=1, as vm-sanitize-test), with the sampled sweep: it checks the C helpers that compiled code calls and the
# exits it takes under ASan and UBSan; the emitted machine code itself is not instrumented, so a fault there shows only
# as a crash. SANITIZE_JIT=off runs the same tests on the interpreter alone (vm-sanitize-test runs the default, `on`).
# Both weekly in sweep.yml.
SANITIZE_JIT ?= always
vm-sanitize-jit-test: vm-sanitize-build
	AGENTICA_REQUIRE_VM=1 AGENTICA_JIT=$(SANITIZE_JIT) AGENTICA_SWEEP=$${AGENTICA_SWEEP:-sampled} $(MAKE) --no-print-directory test-py \
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

# SHARD=I/N runs shard I of N of the modules (the sanitize column of tests/shard_weights.txt, as the CI shards do).
vm-sanitize-test: vm-sanitize-build
	@$(MAKE) --no-print-directory test-py TESTS="$(VM_PY_TESTS)" JOBS=$(SANITIZE_JOBS) SHARD_WEIGHTS=sanitize

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

# With libffi (Linux and macOS x86_64 and arm64, Windows x64) the lint reads vm/ffi_libffi.c, and vm/ffi_none.c is empty, as in the build.
LINT = printf '%s\n' $(VM_LINT_SRC) | xargs -P $(JOBS) -I{} $(CLANG_TIDY) --quiet {} -- $(VM_WARN) $(OSSL_INC) \
  $(if $(FFI_NAMES),-DAGC_FFI -I $(FFI_INC))

vm-lint-release:
	$(LINT) -I $(GC_DIR)/include

# With the define of the libFuzzer build on Linux (mk/vm.mk), so that the JIT comparison of vm/fuzz_libfuzzer.c is read.
vm-lint-sanitize:
	$(LINT) -DAGC_NO_GC -fsanitize=address,undefined $(if $(filter Linux,$(shell uname -s)),-DAGC_FUZZ_JIT_WRAP)

vm-lint-gcstress:
	$(LINT) -I $(GC_DIR)/include -DGC_DEBUG -DAGC_GC_STRESS

# cchecker (https://github.com/agentica-lang/cchecker): the project rules for C (blocking calls on short paths, locks on every
# path, ownership, collector values) plus gcc -fanalyzer and clang-tidy, over a VM compile database (`make cchecker-db`).
# It is an Agentica program, so dist/agentica runs it; it needs gcc 10+, clang and clang-tidy on PATH. The release has no
# binary: the tag is cloned into build/cchecker/ and its commit must be the pinned one (a new release is CCHECKER_VERSION,
# CCHECKER_COMMIT and its include/cchecker.h copied to vm/cchecker.h). The settings are cchecker.toml, the accepted
# findings cchecker-baseline.json (references/ci.md of the development skill says how to change both). vm/tests/ is
# test harness code and not checked: cchecker reads a database of its own without it (CCHECKER_DB), so each run is a
# full run, which checks the names of the settings and reports a stale ignore of the rules. It exits 1 on a finding
# that is not in the baseline, which fails the CI job `cchecker`.
CCHECKER_VERSION := 0.6.1
CCHECKER_COMMIT := 9dbf8edc47c06a276a1f26338ffd13d13c7437fe
CCHECKER_DIR := build/cchecker/$(CCHECKER_VERSION)
CCHECKER_FLAGS ?=
CCHECKER_DB := build/cchecker/compile_commands.json

.PHONY: cchecker cchecker-update-baseline cchecker-clone

# An existing clone is trusted by its path: change the version and the commit together.
$(CCHECKER_DIR)/cchecker.agc:
	@rm -rf $(CCHECKER_DIR) $(CCHECKER_DIR).tmp && mkdir -p build/cchecker
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch $(CCHECKER_VERSION) https://github.com/agentica-lang/cchecker $(CCHECKER_DIR).tmp
	@[ "$$(git -C $(CCHECKER_DIR).tmp rev-parse HEAD)" = "$(CCHECKER_COMMIT)" ] || { echo "cchecker $(CCHECKER_VERSION) is not commit $(CCHECKER_COMMIT)" >&2; rm -rf $(CCHECKER_DIR).tmp; exit 1; }
	mv $(CCHECKER_DIR).tmp $(CCHECKER_DIR)

# The clone alone, which CI runs as a step of its own (a network failure is then not a failed check).
cchecker-clone: $(CCHECKER_DIR)/cchecker.agc

# Run from the root of the checkout: cchecker reads paths relative to the working directory.
CCHECKER = $(RUN_PROGRAM) dist/agentica$(EXE) $(CCHECKER_DIR)/cchecker.agc -p $(CCHECKER_DB) -c cchecker.toml -j $(JOBS) \
  --baseline cchecker-baseline.json $(CCHECKER_FLAGS)

.PHONY: cchecker-db
cchecker-db: $(CC_DB_DEPS) | $(CC_DB_ORDER)
	@mkdir -p $(dir $(CCHECKER_DB))
	@sh vm/tools/compile-commands.sh '$(CURDIR)' $(VM_OBJ) '$(filter-out vm/tests/%,$(CC_DB_SRC))' '' $(VM_CC) $(VM_CFLAGS) \
	  > '$(CCHECKER_DB).new' || { rm -f '$(CCHECKER_DB).new'; exit 1; }
	@mv '$(CCHECKER_DB).new' '$(CCHECKER_DB)'

cchecker: $(PRODUCT) $(CCHECKER_DIR)/cchecker.agc cchecker-db
	$(CCHECKER)

# Accepts today's findings: rewrites the baseline (the diff is the review).
cchecker-update-baseline: $(PRODUCT) $(CCHECKER_DIR)/cchecker.agc cchecker-db
	$(CCHECKER) --update-baseline

vm-layers: $(VM_OBJS) $(VM_OBJ)/agentica.o $(VM_OBJ)/launch.o
	for h in vm/*.h vm/jit/*.h; do $(VM_CC) $(VM_CFLAGS) -fsyntax-only -x c -include $$h /dev/null || exit 1; done
	sh vm/tools/check-layers.sh $(VM_OBJ)
	sh vm/tools/check-layers-test.sh $(VM_OBJ) $(VM_CC) $(VM_CFLAGS)

# The code layout of the `--jit off` hot loop (tools/layout_check.py has the rules): builds BASE (a Git revision, default
# the merge base with origin/master) in a worktree under build/ with this make's variables, and compares the first binary
# of the bootstrap, which has the text of dist/agentica, with this tree's. Release mode on Linux x86-64 only. Its exit
# code goes to build/layout-check.rc (make itself exits 2 on any failure): 4 when plain_turn has other instructions or
# moved inside vm/interp.c, which an intended change accepts with the `layout-change` label in CI.
BASE ?=
LAYOUT_TREE ?= $(CURDIR)/build/layout-base
LAYOUT_RC := build/layout-check.rc
ifneq ($(filter layout-check,$(MAKECMDGOALS)),)
ifneq ($(filter 1,$(SANITIZE) $(TSAN) $(GC_STRESS) $(COVERAGE) $(LIBFUZZ)),)
$(error layout-check: release mode only)
endif
ifneq ($(shell uname -sm),Linux x86_64)
$(error layout-check: Linux x86-64 only)
endif
endif
layout-check: $(BOOT)
	@mkdir -p build; rm -f $(LAYOUT_RC); \
	trap '$(PYTHON) tools/layout_check.py clean "$(LAYOUT_TREE)"' EXIT; \
	rc=0; $(PYTHON) tools/layout_check.py prepare '$(BASE)' '$(LAYOUT_TREE)' || rc=$$?; \
	if [ $$rc -eq 0 ]; then \
	  $(MAKE) --no-print-directory -C '$(LAYOUT_TREE)' $(BOOT) \
	    && $(PYTHON) tools/layout_check.py compare '$(LAYOUT_TREE)' $(BOOT) $(VM_OBJ)/interp.o; rc=$$?; \
	elif [ $$rc -eq 3 ]; then rc=0; fi; \
	echo $$rc > $(LAYOUT_RC); exit $$rc
