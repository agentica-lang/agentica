# The release steps of the host platform (release-check, release-package, release-smoke) and the RELEASE_* variables
# that name the archive. release.yml runs them on each of the five systems.

.PHONY: release-check release-package release-smoke

# The release steps of the host's platform (release.yml runs them on each of the five). RELEASE_PLATFORM names the archive
# (linux-x86_64, linux-arm64, windows-x86_64, macos-x86_64, macos-arm64); release-check wants VM_GLIBC (Linux) or MACOSX_DEPLOYMENT_TARGET
# (macOS) in the environment, the floor the binary was built for.
RELEASE_PLATFORM ?= $(if $(filter Windows_NT,$(VM_OS)),windows,$(if $(filter Darwin,$(shell uname -s)),macos,linux))-$(if $(filter arm64 aarch64,$(shell uname -m)),arm64,x86_64)
RELEASE_OS := $(firstword $(subst -, ,$(RELEASE_PLATFORM)))
RELEASE_ARCH := $(lastword $(subst -, ,$(RELEASE_PLATFORM)))
RELEASE_FORMAT := $(if $(filter windows,$(RELEASE_OS)),pe,$(if $(filter macos,$(RELEASE_OS)),macho,elf))
RELEASE_FLOOR := $(if $(filter linux,$(RELEASE_OS)),$(VM_GLIBC),$(if $(filter macos,$(RELEASE_OS)),$(MACOSX_DEPLOYMENT_TARGET)))

# The format checks of the stripped binary: architecture, floor, libraries, hardening (tools/release-check.sh)
release-check: $(PRODUCT)
	tools/release-check.sh $(RELEASE_FORMAT) $(PRODUCT) $(RELEASE_ARCH) $(RELEASE_FLOOR)

# dist/agentica-VERSION-PLATFORM.(tar.gz|zip) with the licenses (tools/release.py)
release-package: $(PRODUCT)
	$(PYTHON) tools/release.py package --platform $(RELEASE_PLATFORM) --binary $(PRODUCT) --out dist

# The package, extracted away from the checkout, used with a controlled PATH
release-smoke:
	$(PYTHON) -I tools/release.py smoke dist/$$($(PYTHON) tools/release.py name --platform $(RELEASE_PLATFORM)) --platform $(RELEASE_PLATFORM) --binary $(PRODUCT)
