# The Python tests: the pytest runner (test, test-slow, test-py, py-test/%), the test groups (tests, KIND, DOCKER, WINE),
# conformance, goldens, smoke, benchmarks, jscpd (dup-check) and the Ubuntu test container. The C tests are in mk/vm-test.mk.

.PHONY: test test-slow test-py tests tests-host tests-files tests-docker tests-wine test-cli conformance conformance-report \
  test-bdd smoke goldens bench eval-references vm-latency vm-task-map test-distribution vm-golden-check dup-check dup-baseline \
  docker-test-image windows-docker-remove-check windows-docker-remove-wine-check test-remove-actions test-jit-off

# Tests live in tests/test_<area>.py and run through pytest; unittest.TestCase modules remain supported.
# TESTS names modules, or directories that hold them (the default is tests/). Design: references/ci.md,
# docs/future/18-front-end-language.md §18.7.
# Fast Python tests:           make test [TESTS="tests/test_vm_bits.py ..."]
# Test groups:                 make tests KIND=fast|files|slow|all [DOCKER=1|WINE=1]
# More or fewer workers:       make test JOBS=8
TESTS ?= tests/
TESTS_EXPLICIT = $(if $(filter file,$(origin TESTS)),,1)
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
	@if [ -n "$(JUNIT_DIR)" ]; then mkdir -p "$(JUNIT_DIR)"; fi
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
# JUNIT_DIR (the conformance targets set it) makes each module write DIR/<module>.xml, which tools/conformance.py reads.
PYTEST_RUNNER ?= $(POETRY) run python -m pytest
JUNIT_DIR ?=
JUNIT_ARG = $(if $(JUNIT_DIR),--junitxml=$(JUNIT_DIR)/$(patsubst test_%.py,test_%,$(notdir $*)).xml)
py-test/%: FORCE
	@echo "pytest $*"
	@if command -v timeout >/dev/null 2>&1; then \
	  timeout -k 10 $(MODULE_LIMIT) $(PYTEST_RUNNER) "$*" $(JUNIT_ARG); status=$$?; \
	  if [ $$status -eq 124 ] || [ $$status -eq 137 ]; then \
	    echo "pytest $*: hung, stopped after $(MODULE_LIMIT) s (the module limit)" >&2; \
	  fi; \
	  exit $$status; \
	else $(PYTEST_RUNNER) "$*" $(JUNIT_ARG); fi

# The tests that run the product command line on dist/agentica (make test runs them too, with the rest): the options, the
# diagnostics, the programs, `agentica test`, `agentica run`.
CLI_TESTS ?= tests/test_cli_forms.py tests/test_cli_check.py tests/test_check_stdin.py tests/test_examples.py tests/test_filesystem.py tests/test_process.py tests/test_process_bdd.py tests/test_source_paths.py \
  tests/test_source_utf8.py tests/test_bdd.py tests/test_bdd_posix.py tests/test_modules.py tests/test_vm_diff_8.py tests/test_single_binary.py
test-cli: $(PRODUCT)
	AGENTICA_TEST_EXECUTABLE="$(CURDIR)/$(PRODUCT)" $(MAKE) --no-print-directory test-py TESTS="$(CLI_TESTS)" AGENTICA_TEST_SLOW=

# The conformance matrix (platforms.yml; tools/conformance.py has the areas and the modules of each): every area runs on
# Linux, Windows, macOS Intel and macOS ARM, and the report fails when an area has no passed case, a module did not
# finish, or a case was skipped without a "host-only:" reason. conformance-area/NAME runs one area into
# $(CONFORMANCE_DIR)/NAME; conformance runs all of them (a failed area does not stop the next) and then the report. The
# tasks area runs its modules one at a time, because its timing cases need the CPU (make vm-task-map).
CONFORMANCE_DIR ?= build/conformance
CONFORMANCE_PLATFORM ?=
# The golden area samples the --max-steps sweep (the full one is the sweep of CI); env.txt records the tier and the sweep
# that the area really ran with, and the report prints them.
conformance-area/%: $(PRODUCT) FORCE
	@rm -rf "$(CONFORMANCE_DIR)/$*"
	@mkdir -p "$(CONFORMANCE_DIR)/$*"
	@sweep="$(if $(filter golden,$*),sampled,$(AGENTICA_SWEEP))"; \
	  echo "slow= sweep=$$sweep" > "$(CONFORMANCE_DIR)/$*/env.txt"; \
	  AGENTICA_SWEEP="$$sweep" $(MAKE) --no-print-directory test-py AGENTICA_TEST_SLOW= JUNIT_DIR="$(CONFORMANCE_DIR)/$*" \
	  JOBS=$(if $(filter tasks,$*),1,$(JOBS)) TESTS="$(shell $(PYTHON) tools/conformance.py modules $*)"

conformance-report:
	$(PYTHON) tools/conformance.py report "$(CONFORMANCE_DIR)" $(if $(CONFORMANCE_PLATFORM),--platform $(CONFORMANCE_PLATFORM))

conformance: $(PRODUCT)
	@status=0; for area in $$($(PYTHON) tools/conformance.py areas); do \
	  $(MAKE) --no-print-directory conformance-area/$$area || status=1; \
	done; \
	$(MAKE) --no-print-directory conformance-report || status=1; exit $$status

# The soak of the interpreter (docs/vm/05-values-execution-builtins.md §6.4, jit-soak.yml), since `--jit on` is the
# default: the conformance areas of this system, plus the destructive group on a GitHub-hosted runner (it needs the
# prebuilt C test binaries, so vm-test-binaries comes first there), with AGENTICA_JIT=off in the environment of every
# VM the tests start (run_vm, Child, `agentica test` and its VMs inherit it; vm_environment() keeps it). A test that
# passes --jit or sets AGENTICA_JIT itself keeps its own mode, since the flag wins; tests/test_vm_jit.py has a canary
# that fails if the variable stops reaching the VMs. The mode must change no result, so a failure here is a bug of one
# tier or a test that depends on the mode; the report in the job summary names the failed cases. Locally:
# `AGENTICA_JIT=off make test` runs the whole suite (the conformance areas leave out the source checks).
test-jit-off: $(PRODUCT) $(if $(filter true,$(GITHUB_ACTIONS)),vm-test-binaries)
	@status=0; export AGENTICA_JIT=off; \
	  if [ "$${GITHUB_ACTIONS:-}" = true ]; then $(MAKE) --no-print-directory test-remove-actions || status=1; fi; \
	  $(MAKE) --no-print-directory conformance || status=1; exit $$status

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
	@if [ -L $@ ]; then echo "$@ is a symlink: npm ci would empty its target; remove the link (each worktree installs its own)"; exit 1; fi
	npm ci --prefix tools/jscpd --ignore-scripts --no-audit --no-fund
	touch $@

dup-check: tools/jscpd/node_modules
	$(JSCPD) --baseline .jscpd-baseline.json --fail-on-new-clones

dup-baseline: tools/jscpd/node_modules
	$(JSCPD) --baseline .jscpd-baseline.json --update-baseline --reporters silent

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
