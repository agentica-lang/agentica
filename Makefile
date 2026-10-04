RACO ?= raco
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
TESTS ?= tests/

.PHONY: build test exe clean test-bdd version

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

test-bdd: exe
	dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc

clean:
	find . -name compiled -type d -prune -exec rm -rf {} +
	rm -rf dist
