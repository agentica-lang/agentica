# The documentation site (Hugo): site, site-serve, site-sass, the highlighter's npm install and site-versions (every release).
# The look, the layouts and the highlighter come from the docs theme, the submodule site/themes/docs-theme.

.PHONY: site site-serve site-sass site-versions

DART_SASS ?= $(HOME)/.local/opt/dart-sass

site site-serve site-sass: export PATH := $(DART_SASS):$(PATH)
site site-serve: export HUGO_PARAMS_VERSION = $(AGC_VERSION)

THEME := site/themes/docs-theme

site-sass:
	@test -e $(THEME)/hugo.toml || { echo "The site needs its theme: git submodule update --init $(THEME)" >&2; exit 1; }
	@command -v sass >/dev/null || { echo "The site needs Dart Sass: put its sass on PATH or in $(DART_SASS) (pinned version in .github/workflows/pages.yml)" >&2; exit 1; }

$(THEME)/highlight/node_modules: $(THEME)/highlight/package.json $(THEME)/highlight/package-lock.json
	@if [ -L $@ ]; then echo "$@ is a symlink: npm ci would empty its target; remove the link (each worktree installs its own)"; exit 1; fi
	npm ci --prefix $(THEME)/highlight --ignore-scripts --no-audit --no-fund
	touch $@

# --strict: the site has every kind of block, so a grammar scope that no longer matches fails the build.
site: site-sass $(THEME)/highlight/node_modules
	hugo --cleanDestinationDir --source site --panicOnWarning $(HUGO_FLAGS)
	node $(THEME)/highlight/highlight.mjs --strict site/public

site-serve: site-sass
	hugo server --source site

# One site per release plus dev, as pages.yml deploys it (tools/site_versions.py); serve the output with
# `python3 -m http.server 8000 -d build/site-versions/public`. SITE_BASE_URL is where the root is served.
SITE_BASE_URL ?= http://localhost:8000/

site-versions:
	$(PYTHON) -I tools/site_versions.py build --base-url $(SITE_BASE_URL)
