# The root of the build: the defaults and the variables that more than one file uses, the default goal, `help`, and the
# include list. The rules are in mk/*.mk, one file per area; the order of the includes is part of the contract: a
# variable that make expands while it reads a file (`:=`, `ifeq`, a prerequisite list) is set before the file that uses it.

JOBS ?= $(shell nproc 2>/dev/null || echo 4)
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

# The tools that test.mk and release.mk call.
PYTHON ?= python3
POETRY ?= poetry

# Read by the version target, the VM flags (vm.mk) and the site (site.mk).
AGC_VERSION := $(shell cat VERSION)

# `make` builds the product, dist/agentica: the VM with the front end inside (docs/future/18-front-end-language.md §18.2 and
# §18.8). It needs only a C toolchain: the bootstrap (mk/bootstrap.mk) starts from bootstrap/stage0.agcb. The host is the default
# target; `make windows-docker-check` cross-builds the Windows VM on a Linux or macOS host with docker (VM_OS above).
.DEFAULT_GOAL := all

.PHONY: all agentica clean version help FORCE

all: $(PRODUCT)

agentica: $(PRODUCT)

# Targets that step 8d-2 removed. They fail on purpose: without a rule, `make vm` would find the vm/ folder and say nothing to do.
.PHONY: vm exe cli bdd-driver
vm exe cli bdd-driver:
	@echo "make $@ is gone: the product is one binary, dist/agentica (the VM with the front end); run make" >&2; exit 1

# A recipe that fails leaves no half-written target for the next make to take as up to date. The stages (mk/bootstrap.mk) also remove
# their output before they write it, so a compiler that exits 0 without writing cannot pass for the previous file.
.DELETE_ON_ERROR:

# The version is the one line of the VERSION file (C gets it as AGC_VERSION).
version:
	@printf '%s' '$(AGC_VERSION)'

clean:
	rm -rf dist build site/public site/resources

# One file per area, included in this order (vm.mk first: it defines the build mode that the others read):
#   mk/vm.mk         the C VM: sources, build modes, third-party libraries, system or vendored libgc, OpenSSL and zlib
#   mk/bootstrap.mk  stage0 to stage3, the embedded data, dist/agentica, fixed-point, stage0-check
#   mk/test.mk       the Python test runner and groups, conformance, goldens, smoke, fmt-check, check-compiler,
#                    dup-check, the Docker test image
#   mk/vm-test.mk    the C tests and the VM checks: sanitizers, TSan, GC stress, fuzz, multicore, lint, layers
#   mk/windows.mk    the Windows cross build and check in Docker (llvm-mingw and Wine)
#   mk/release.mk    the release steps of the host platform
#   mk/site.mk       the documentation site
include mk/vm.mk
include mk/bootstrap.mk
include mk/test.mk
include mk/vm-test.mk
include mk/windows.mk
include mk/release.mk
include mk/site.mk

help:
	@printf '%s\n' \
	  'make                     build dist/agentica (the VM with the front end inside)' \
	  'make fixed-point         check that dist/agentica compiles the same front end' \
	  'make vm-test             the C tests' \
	  'make test [TESTS=...]    the fast Python tests' \
	  'make test-slow           the slow Python tests (CI)' \
	  'make tests KIND=fast|files|slow|all [DOCKER=1|WINE=1]' \
	  'make vm-tsan             the C tests of the shared-state code, under ThreadSanitizer' \
	  'make goldens             rewrite the VM, CLI and front-end goldens' \
	  'make stage0              refresh bootstrap/stage0.agcb after the fixed point holds' \
	  'make windows-docker-check  the Windows cross build and tests, in Docker with Wine' \
	  'make site                build the documentation site' \
	  'make clean               remove dist/, build/ and the site output' \
	  '' \
	  'The rules are in mk/*.mk, one file per area (the list is above the includes in the Makefile).' \
	  'Each file starts with a comment that says what it owns; AGENTS.md has the other commands.'
