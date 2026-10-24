# The local Windows check without a Windows machine: the llvm-mingw and Wine image, the cross build of dist/agentica.exe
# and the C tests, and the check that runs them. WINDOWS_CROSS is the set of variables that selects the Windows build.
# windows-docker-remove-check, windows-docker-remove-wine-check and test-remove-actions are in mk/test.mk.

.PHONY: windows-docker-image windows-docker-wrappers windows-docker-build windows-docker-check

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
  AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored AGENTICA_ZLIB=vendored
# The modules the vm-windows job of platforms.yml runs: the bootstrap binary alone, then the product. TESTS= picks
# others (test_cli_forms.py drives only the command line, for instance).
# tests/test_process.py, tests/test_process_lifecycle.py and tests/test_vm_child_channel.py stay out: their peers are
# host programs that Wine cannot start, and the stop case of the lifecycle module needs a Windows console (it would
# need a Wine skip, which the native job must not have).
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
