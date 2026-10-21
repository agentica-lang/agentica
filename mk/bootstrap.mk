# The binary and its bootstrap: stage0 to stage3, the embedded data, the first binary, dist/agentica, fixed-point,
# stage0 and stage0-check. Needs the VM variables of mk/vm.mk (VM_BUILD, VM_OBJ, AGENTICA_OBJS parts);
# EXE comes from the root Makefile and mk/vm.mk sets it again.

.PHONY: bootstrap-smoke stage1 stage2 stage3 stage0 stage0-check fixed-point

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
# The files of compiler/ that std/analysis compiles into a user's program as the private std/internal/compiler/ (stdlib/CORE
# lists them, relative to compiler/; tests/test_stdlib_modules.py checks the list). The binary carries them with the std/
# sources.
CORE_NAMES := $(shell cat stdlib/CORE)
CORE_FILES := $(addprefix compiler/,$(CORE_NAMES))
# Every .agc file under compiler/, in all its folders, is an input, except compiler/embedded/: those programs are compiled by
# the stages, not into them. compiler/agentica.toml is not an input: it holds the style rules for the style test.
STAGE_INPUTS := $(sort $(shell find compiler -name '*.agc' -not -path 'compiler/embedded/*')) stdlib/MODULES $(STD_FILES) VERSION
# The runner and the default step program of `agentica test` (compiler/bdd/bdd_driver.agc), compiled at build time with the front
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

# The first binary of the bootstrap, linked with stage0 (never shipped), passes the native contracts of
# tests/test_platform_bootstrap.py on its own, before anything it compiled runs (platforms.yml runs it on every system).
bootstrap-smoke: $(BOOT)
	AGENTICA_VM_BINARY=$(BOOT) $(MAKE) --no-print-directory test-py TESTS="tests/test_platform_bootstrap.py"

ifneq ($(filter 1,$(GC_STRESS) $(TSAN)),)
$(STAGE_DIR)/stage2.agcb $(EMBEDDED_PROGRAMS):
	@echo "$@ is missing: the GC stress and TSan builds link the front end of the release build; run make first" >&2; exit 1
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
$(VM_BUILD)/embedded.s: vm/tools/gen-embedded.sh stdlib/MODULES stdlib/CORE $(STAGE_DIR)/stage2.agcb $(EMBEDDED_PROGRAMS) $(STD_FILES) $(CORE_FILES) $(EMBEDDED_STAMP)
	@mkdir -p $(VM_BUILD)
	AGENTICA_OBJECT_FORMAT=$(EMBEDDED_FORMAT) sh vm/tools/gen-embedded.sh $(STAGE_DIR)/stage2.agcb stdlib stdlib/MODULES $(EMBEDDED_PROGRAMS) stdlib/CORE compiler > $@

$(VM_BUILD)/bootstrap/embedded.s: vm/tools/gen-embedded.sh stdlib/MODULES $(STAGE0) $(STD_FILES) $(EMBEDDED_STAMP)
	@mkdir -p $(VM_BUILD)/bootstrap
	AGENTICA_OBJECT_FORMAT=$(EMBEDDED_FORMAT) sh vm/tools/gen-embedded.sh $(STAGE0) stdlib stdlib/MODULES > $@

$(VM_OBJ)/embedded.o: $(VM_BUILD)/embedded.s $(VM_OBJ_STAMP) $(STAGE_DIR)/stage2.agcb $(EMBEDDED_PROGRAMS) $(STD_FILES) $(CORE_FILES)
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

# make stage0-check BASE_STAGE0=<file>: stage2 built from BASE_STAGE0 (the stage0 of the base branch) with this checkout's
# compiler/ must be the checked-in stage0, byte for byte (references/ci.md, "Refreshing stage0"). A stage0 compiled with another
# seed cannot pass; the owner approves that one by hand. The stages go to their own folder, and the first binary and its
# embedded seed are removed before and after, so a later make links them from bootstrap/stage0.agcb again (the seed is a
# timestamp dependency of them, and an older file would not relink).
STAGE_CHECK_DIR := build/stage-check
STAGE_CHECK_BOOT := $(BOOT) $(VM_BUILD)/bootstrap/embedded.s $(VM_OBJ)/embedded-stage0.o
stage0-check:
	@test -n "$(BASE_STAGE0)" -a -f "$(BASE_STAGE0)" || { echo "usage: make stage0-check BASE_STAGE0=<stage0 of the base branch>" >&2; exit 1; }
	rm -rf $(STAGE_CHECK_DIR) $(STAGE_CHECK_BOOT)
	status=0; \
	$(MAKE) --no-print-directory STAGE0="$(BASE_STAGE0)" STAGE_DIR=$(STAGE_CHECK_DIR) stage2 || status=$$?; \
	rm -f $(STAGE_CHECK_BOOT); \
	test $$status -eq 0 || { echo "stage0-check: could not build stage2 from $(BASE_STAGE0)" >&2; exit $$status; }
	cmp $(STAGE_CHECK_DIR)/stage2.agcb $(STAGE0) || { \
	  echo "stage0-check: bootstrap/stage0.agcb is not the stage2 that the stage0 of the base branch builds from this compiler/." >&2; \
	  echo "A refresh must be made with 'make fixed-point stage0' on the base branch's stage0. A stage0 compiled with another seed" >&2; \
	  echo "(STAGE1_COMPILER) cannot pass this check: say so in the PR; the owner approves it by hand." >&2; exit 1; }
	@echo "stage0-check: ok, $(STAGE0) is the stage2 built from $(BASE_STAGE0)"
