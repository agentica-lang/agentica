# The documentation site (Hugo): site, site-serve, site-sass and the highlighter's npm install.

.PHONY: site site-serve site-sass

DART_SASS ?= $(HOME)/.local/opt/dart-sass

site site-serve site-sass: export PATH := $(DART_SASS):$(PATH)
site site-serve: export HUGO_PARAMS_VERSION = $(AGC_VERSION)

site-sass:
	@command -v sass >/dev/null || { echo "The site needs Dart Sass: put its sass on PATH or in $(DART_SASS) (pinned version in .github/workflows/pages.yml)" >&2; exit 1; }

site/highlight/node_modules: site/highlight/package.json site/highlight/package-lock.json
	@if [ -L $@ ]; then echo "$@ is a symlink: npm ci would empty its target; remove the link (each worktree installs its own)"; exit 1; fi
	npm ci --prefix site/highlight --ignore-scripts --no-audit --no-fund
	touch $@

site: site-sass site/highlight/node_modules
	hugo --cleanDestinationDir --source site --panicOnWarning $(HUGO_FLAGS)
	node site/highlight/highlight.mjs site/public

site-serve: site-sass
	hugo server --source site
